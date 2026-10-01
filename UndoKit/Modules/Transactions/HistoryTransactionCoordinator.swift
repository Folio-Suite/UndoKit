// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

enum HistoryHostCallbackContext {
    @TaskLocal static var activeTransactions: Set<ObjectIdentifier> = []
}

/// Owns one scope's ordered transaction lifecycle. Only this file mutates the
/// waiting queue and closure state; persistence transitions live alongside it.
@MainActor final class HistoryTransactionCoordinator: HistoryRetainedActivity {
    var snapshotDidChange: (@MainActor (HistorySnapshot) -> Void)?
    var snapshot = HistorySnapshot(canUndo: false, canRedo: false,
                                   isSuspended: false, hasPending: false)
    enum Request {
        case command(HistoryCommand)
        case undo(expectedGeneration: UUID?)
        case redo(expectedGeneration: UUID?)
    }

    struct Waiting {
        let id: UUID
        let request: Request
        let continuation: CheckedContinuation<HistoryResult, Never>
    }

    let history: HistoryScopeStorage
    let host: any HistoryHost
    var store: HistoryStore { history.store }
    var scope: UUID { history.scope }
    var limits: HistoryLimits { history.limits }
    var context: NSManagedObjectContext { history.context }
    private var queue: [Waiting] = []
    private var draining = false
    private(set) var closing = false
    private(set) var closed = false
    var reconciling = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    struct SessionGroup {
        let id: UUID
        let effects: [HistoryEffect]
        var applied = true
    }
    var sessionGroups: [SessionGroup] = []
    /// Prepared transactions below this sequence predate this engine session.
    var sessionStartSequence: Int64 = 1
    var sessionEffectBytes: Int64 {
        sessionGroups.reduce(0) { total, group in
            total + group.effects.reduce(0) { bytes, effect in
                bytes + Int64(effect.undo.data.count + effect.redo.data.count)
            }
        }
    }

    init(history: HistoryScopeStorage, host: any HistoryHost) {
        self.history = history
        self.host = host
    }

    var isExecuting: Bool { draining }
    var isActive: Bool { draining || !queue.isEmpty || reconciling }
    var hasPending: Bool { draining || !queue.isEmpty }

    func open(mode: HistoryScopeOpenMode) async throws {
        try history.register(mode: mode)
        sessionStartSequence = try history.scopeRecord().int64("nextSequence")
        await reconcileOnOpen()
        try refreshSnapshot()
        try releaseSessionReferences()
    }

    func enqueue(_ request: Request) async -> HistoryResult {
        guard !HistoryHostCallbackContext.activeTransactions.contains(ObjectIdentifier(self)) else {
            return .failure(HistoryFailure(.busy, stage: .admission, disposition: .usable))
        }
        if Task.isCancelled {
            return .failure(HistoryFailure(.cancelled, stage: .admission, disposition: .usable))
        }
        if store.writeFailed {
            return .failure(HistoryFailure(.storage, stage: .admission, disposition: .suspended))
        }
        guard !closed, !closing, !reconciling, !store.closing, !store.closed,
              !store.maintenance else {
            return .failure(HistoryFailure(.busy, stage: .admission, disposition: .usable))
        }
        guard queue.count < limits.maxQueueDepth else {
            return .failure(HistoryFailure(.capacity, stage: .admission, disposition: .usable))
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.append(Waiting(id: id, request: request, continuation: continuation))
                updateSnapshot()
                if !draining {
                    draining = true
                    Task { await drain() }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelQueued(id) }
        }
    }

    private func cancelQueued(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiting = queue.remove(at: index)
        waiting.continuation.resume(returning: .failure(
            HistoryFailure(.cancelled, stage: .admission, disposition: .usable)
        ))
        updateSnapshot()
    }

    private func drain() async {
        while !queue.isEmpty {
            let waiting = queue.removeFirst()
            let result = await execute(waiting.request)
            waiting.continuation.resume(returning: result)
            updateSnapshot()
        }
        draining = false
        updateSnapshot()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func beginClosing(protection: any HistoryRecoveryProtection) {
        protection.invalidateRecoveryPlans()
        guard !closing, !closed else { return }
        closing = true
        let unexecuted = queue
        queue.removeAll()
        for waiting in unexecuted {
            waiting.continuation.resume(returning: .failure(
                HistoryFailure(.busy, stage: .admission, disposition: .usable)
            ))
        }
    }

    func close(protection: any HistoryRecoveryProtection) async throws {
        try store.activity.requireClosureAdmission(in: store)
        if closed { return }
        guard !reconciling else {
            throw HistoryFailure(.busy, stage: .reconciliation, disposition: .suspended)
        }
        beginClosing(protection: protection)
        if draining {
            await withCheckedContinuation { continuation in closeWaiters.append(continuation) }
        }
        do {
            try releaseSessionReferences()
            try history.saveContext()
        } catch {
            publishSnapshot(canUndo: false, canRedo: false, isSuspended: true,
                            hasPending: false, generation: snapshot.generation)
            throw HistoryFailure(.storage, stage: .finalization, disposition: .suspended,
                                 underlyingDescription: String(describing: error))
        }
        closed = true
        updateSnapshot()
    }
}
