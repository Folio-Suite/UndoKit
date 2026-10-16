// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

enum HistoryHostCallbackContext {
    @TaskLocal static var activeTransactions: Set<ObjectIdentifier> = []
}

/// Native prerequisites participate in the transaction owner's existing FIFO.
@MainActor protocol HistoryAdmissionParticipant: AnyObject {
    func capturePrerequisite() throws -> UUID?
    func settlePrerequisite(
        _ id: UUID,
        execute: @escaping @MainActor (HistoryCommand) async -> HistoryResult
    ) async -> HistoryResult?
    func admissionCompleted(_ result: HistoryResult) async
    func admissionClosing()
    func admissionFailure() -> HistoryFailure?
}

extension HistoryAdmissionParticipant {
    func admissionClosing() {}
    func admissionFailure() -> HistoryFailure? { nil }
}

/// Owns one scope's ordered transaction lifecycle. Only this file mutates the
/// waiting queue and closure state; persistence transitions live alongside it.
@MainActor final class HistoryTransactionCoordinator: HistoryRetainedActivity {
    var snapshotDidChange: (@MainActor (HistorySnapshot) -> Void)?
    var snapshot = HistorySnapshot(
        canUndo: false, canRedo: false,
        isSuspended: false, hasPending: false)
    enum Request {
        case command(HistoryCommand)
        case settle
        case undo(expectedGeneration: UUID?)
        case redo(expectedGeneration: UUID?)
    }

    /// A slot is installed before encoding can suspend. Its terminal result is
    /// retained even if cancellation or closure wins before a waiter attaches.
    @MainActor final class Reservation {
        let id = UUID()
        let generation: UUID
        let prerequisite: UUID?
        #if DEBUG
        var injectFinalizationFailure = false
        #endif
        var request: Request?
        /// Prerequisite work is independent of a dependent request's preparation.
        var executionStarted = false
        var terminal: HistoryResult?
        var waiters: [CheckedContinuation<HistoryResult, Never>] = []
        init(generation: UUID, prerequisite: UUID?) {
            self.generation = generation
            self.prerequisite = prerequisite
        }
        func finish(_ result: HistoryResult) {
            guard terminal == nil else { return }
            terminal = result
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume(returning: result) }
        }
    }
    weak var participant: (any HistoryAdmissionParticipant)?

    let history: HistoryScopeStorage
    let host: any HistoryHost
    var store: HistoryStore { history.store }
    var scope: UUID { history.scope }
    var limits: HistoryLimits { history.limits }
    var context: NSManagedObjectContext { history.context }
    private var queue: [Reservation] = []
    private var activeReservation: Reservation?
    private var draining = false
    private var opening = false
    private(set) var closing = false
    private(set) var closed = false
    var reconciling = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    var positionPolicy = HistoryPositionPolicy()
    /// Prepared transactions below this sequence predate this engine session.
    var sessionStartSequence: Int64 = 1
    var sessionEffectBytes: Int64 {
        positionPolicy.sessionGroups.reduce(0) { total, group in
            total
                + group.effects.reduce(0) { bytes, effect in
                    bytes + Int64(effect.undo.data.count + effect.redo.data.count)
                }
        }
    }

    init(history: HistoryScopeStorage, host: any HistoryHost) {
        self.history = history
        self.host = host
    }

    var isExecuting: Bool { draining }
    var isActive: Bool { opening || draining || !queue.isEmpty || reconciling }
    var hasPending: Bool { draining || !queue.isEmpty }

    func open(mode: HistoryScopeOpenMode) async throws {
        opening = true
        defer {
            opening = false
            resumeClosureIfIdle()
        }
        try history.register(mode: mode)
        sessionStartSequence = try history.scopeRecord().nextSequence
        await reconcileOnOpen()
        try refreshSnapshot()
        try releaseSessionReferences()
    }

    func reserve() -> Result<Reservation, HistoryFailure> {
        guard !HistoryHostCallbackContext.activeTransactions.contains(ObjectIdentifier(self)) else {
            return .failure(HistoryFailure(.busy, stage: .admission, disposition: .usable))
        }
        guard !Task.isCancelled else {
            return .failure(HistoryFailure(.cancelled, stage: .admission, disposition: .usable))
        }
        guard !store.writeFailed, !snapshot.isSuspended else {
            return .failure(
                HistoryFailure(
                    store.writeFailed ? .storage : .unresolved,
                    stage: .admission, disposition: .suspended))
        }
        guard !opening, !closed, !closing, !reconciling, !store.closing, !store.closed,
            !store.maintenance, let generation = snapshot.generation
        else {
            return .failure(HistoryFailure(.busy, stage: .admission, disposition: .usable))
        }
        guard queue.count < limits.maxQueueDepth else {
            return .failure(HistoryFailure(.capacity, stage: .admission, disposition: .usable))
        }
        do {
            let reservation = Reservation(
                generation: generation,
                prerequisite: try participant?.capturePrerequisite())
            queue.append(reservation)
            updateSnapshot()
            return .success(reservation)
        } catch let failure as HistoryFailure { return .failure(failure) } catch {
            return .failure(
                HistoryFailure(
                    .invalidInput, stage: .admission, disposition: .usable,
                    underlyingDescription: String(describing: error)))
        }
    }

    func complete(_ reservation: Reservation, request: Request) {
        guard reservation.terminal == nil, reservation.request == nil,
            queue.contains(where: { $0 === reservation })
        else { return }
        reservation.request = request
        startDrain()
    }

    func fail(_ reservation: Reservation, failure: HistoryFailure) {
        if let index = queue.firstIndex(where: { $0 === reservation }) {
            queue.remove(at: index)
        } else {
            guard activeReservation === reservation, !reservation.executionStarted else { return }
        }
        reservation.finish(.failure(failure))
        updateSnapshot()
        startDrain()
    }

    func result(of reservation: Reservation) async -> HistoryResult {
        await withTaskCancellationHandler {
            if Task.isCancelled { cancelQueued(reservation) }
            if let result = reservation.terminal { return result }
            return await withCheckedContinuation { reservation.waiters.append($0) }
        } onCancel: {
            Task { @MainActor in self.cancelQueued(reservation) }
        }
    }

    func enqueue(_ request: Request) async -> HistoryResult {
        switch reserve() {
        case .failure(let failure): return .failure(failure)
        case .success(let reservation):
            complete(reservation, request: request)
            return await result(of: reservation)
        }
    }

    private func cancelQueued(_ reservation: Reservation) {
        fail(reservation, failure: HistoryFailure(.cancelled, stage: .admission, disposition: .usable))
    }

    private func startDrain() {
        guard !draining, queue.first?.request != nil else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while let waiting = queue.first, let request = waiting.request {
            queue.removeFirst()
            activeReservation = waiting
            let result = await executeReserved(request, reservation: waiting)
            // Publication refresh is part of this slot. It cannot change an accepted receipt.
            let callbacks = HistoryHostCallbackContext.activeTransactions.union([ObjectIdentifier(self)])
            await HistoryStore.$deliveringStores.withValue(
                HistoryStore.deliveringStores.union([ObjectIdentifier(store)])
            ) {
                await HistoryHostCallbackContext.$activeTransactions.withValue(callbacks) {
                    await participant?.admissionCompleted(result)
                }
            }
            waiting.finish(result)
            activeReservation = nil
            updateSnapshot()
            if let failure = participant?.admissionFailure() {
                finishWaiting(
                    HistoryFailure(
                        failure.cause, stage: .admission,
                        disposition: failure.disposition, underlyingDescription: failure.underlyingDescription))
            } else if snapshot.isSuspended || store.writeFailed {
                finishWaiting(
                    HistoryFailure(
                        store.writeFailed ? .storage : .unresolved,
                        stage: .admission, disposition: .suspended))
            }
        }
        draining = false
        updateSnapshot()
        resumeClosureIfIdle()
    }

    private func finishWaiting(_ failure: HistoryFailure) {
        let waiting = queue
        queue.removeAll()
        for slot in waiting { slot.finish(.failure(failure)) }
    }

    func resumeClosureIfIdle() {
        guard !opening, !draining, !reconciling else { return }
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func beginClosing(protection: any HistoryRecoveryProtection) {
        protection.invalidateRecoveryPlans()
        guard !closing, !closed else { return }
        closing = true
        if let activeReservation, !activeReservation.executionStarted {
            activeReservation.finish(.failure(HistoryFailure(.busy, stage: .admission, disposition: .usable)))
        }
        participant?.admissionClosing()
        finishWaiting(HistoryFailure(.busy, stage: .admission, disposition: .usable))
        updateSnapshot()
    }

    func close(protection: any HistoryRecoveryProtection) async throws {
        try store.activity.requireClosureAdmission(in: store)
        if closed { return }
        beginClosing(protection: protection)
        if opening || draining || reconciling {
            await withCheckedContinuation { continuation in closeWaiters.append(continuation) }
        }
        do {
            try releaseSessionReferences()
            try history.saveContext()
        } catch {
            publishSnapshot(
                canUndo: false, canRedo: false, isSuspended: true,
                hasPending: false, generation: snapshot.generation)
            throw HistoryFailure(
                .storage, stage: .finalization, disposition: .suspended,
                underlyingDescription: String(describing: error))
        }
        closed = true
        updateSnapshot()
    }
}
