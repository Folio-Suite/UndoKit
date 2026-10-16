// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

enum HistorySessionCallbackContext {
    @TaskLocal static var active: Set<ObjectIdentifier> = []
}

enum HistoryNativeOperation { case settle, undo, redo }

/// One retained owner of ordinary editing and recovery for a working History Scope.
@MainActor public final class HistorySession {
    public let documentURL: URL
    public internal(set) var configuration: HistorySessionConfiguration?
    public internal(set) var status = HistorySessionStatus(
        phase: .opening, canUndo: false,
        canRedo: false, issue: nil, requiresDraftDecision: false)
    public var snapshot: HistorySnapshot {
        engine?.snapshot
            ?? HistorySnapshot(
                canUndo: false, canRedo: false,
                isSuspended: status.phase == .blocked, hasPending: status.phase == .opening)
    }
    public var attachmentCount: Int { observers.count }
    public private(set) lazy var advanced = HistorySessionAdvanced(session: self)

    let lease: any HistoryHostLease
    weak var collection: HistorySessions?
    var engine: HistoryEngine?
    var storeOwner: HistorySessionStoreOwner?
    lazy var nativeCoordinator = HistoryNativeCoordinator(session: self)
    var epoch = UUID()
    var operations: [String: AnyHistoryOperation] = [:]
    var observers: [UUID: @MainActor (HistorySessionStatus) -> Void] = [:]
    var opening = true
    var leaseAcquisitionStarted = false
    var closeRequested = false
    var closing = false
    var closed = false
    var issue: HistoryFailure?
    var nativeIssue: HistoryFailure?
    var requiresDraftDecision = false
    var liveUndo = false
    var liveRedo = false
    var openingWaiters: [CheckedContinuation<Void, Never>] = []
    var closingWaiters: [CheckedContinuation<Void, Never>] = []
    private var nativeOperations: [UUID: Task<Void, Never>] = [:]

    init(documentURL: URL, lease: any HistoryHostLease, collection: HistorySessions) {
        self.documentURL = documentURL
        self.lease = lease
        self.collection = collection
    }

    public func commands<C: Sendable>(for operation: HistoryOperation<C>) throws -> HistoryCommands<C> {
        guard !closed, !closeRequested, let generation = engine?.snapshot.generation else { throw failure(.busy) }
        guard operations[operation.erased.operation]?.identity == operation.erased.identity else {
            throw failure(.identityConflict)
        }
        return HistoryCommands(session: self, operation: operation, epoch: epoch, generation: generation)
    }

    public func attach<Owner: AnyObject>(
        owner: Owner,
        statusDidChange: (@MainActor (Owner, HistorySessionStatus) -> Void)? = nil
    ) throws -> HistoryAttachment {
        let id = UUID()
        try registerAttachment(id: id) { [weak owner] status in
            if let owner { statusDidChange?(owner, status) }
        }
        return HistoryAttachment(session: self, id: id)
    }

    func registerAttachment(id: UUID, status: @escaping @MainActor (HistorySessionStatus) -> Void) throws {
        guard !closed, !closeRequested, observers[id] == nil else { throw failure(.busy) }
        observers[id] = status
        status(self.status)
        collection?.changed()
    }
    func removeAttachment(id: UUID) {
        observers.removeValue(forKey: id)
        collection?.changed()
    }

    func requireHandle(
        epoch expectedEpoch: UUID, generation: UUID,
        operation: AnyHistoryOperation
    ) throws {
        guard expectedEpoch == epoch, generation == engine?.snapshot.generation,
            operations[operation.operation]?.identity == operation.identity
        else { throw failure(.identityConflict) }
        guard !opening, !closed, !closeRequested, nativeIssue == nil, !requiresDraftDecision else {
            throw nativeIssue ?? failure(.busy)
        }
    }

    func submit<C: Sendable>(
        _ values: [C], using handle: HistoryCommands<C>,
        injectFinalizationFailure: Bool = false
    ) async -> HistorySubmissionResult {
        do {
            try requireHandle(epoch: handle.epoch, generation: handle.generation, operation: handle.operation.erased)
            guard let engine else { throw failure(.missingHistory) }
            let reservation: HistoryTransactionCoordinator.Reservation
            switch engine.transaction.reserve() {
            case .success(let admitted): reservation = admitted
            case .failure(let failure): return .unexecuted(failure)
            }
            #if DEBUG
            reservation.injectFinalizationFailure = injectFinalizationFailure
            #endif
            let encoding: Task<Void, Never>?
            do {
                // Capture before encoding can suspend. The host's capture callback freezes
                // references; codecs then run on the registered handler's actor.
                let captured = try values.map(handle.operation.capture)
                let operation = handle.operation
                encoding = Task { @MainActor in
                    do {
                        let command = try await operation.encodeValues(captured, reservation.generation)
                        engine.transaction.complete(reservation, request: .command(command))
                    } catch {
                        engine.transaction.fail(reservation, failure: Self.describeInput(error))
                    }
                }
            } catch {
                engine.transaction.fail(reservation, failure: Self.describeInput(error))
                encoding = nil
            }
            let result = await engine.transaction.result(of: reservation)
            encoding?.cancel()
            return HistorySubmissionResult(result)
        } catch { return .unexecuted(Self.describe(error, stage: .admission)) }
    }

    public func undo() async -> HistorySubmissionResult { await inverse(undo: true) }
    public func redo() async -> HistorySubmissionResult { await inverse(undo: false) }
    private func inverse(undo: Bool) async -> HistorySubmissionResult {
        guard !opening, !closed, !closeRequested, nativeIssue == nil,
            !requiresDraftDecision || nativeCoordinator.canRetryLiveRejection,
            let engine
        else { return .unexecuted(nativeIssue ?? failure(.busy)) }
        nativeCoordinator.prepareExplicitInverse()
        let result =
            undo
            ? await engine.undo(expectedGeneration: engine.snapshot.generation)
            : await engine.redo(expectedGeneration: engine.snapshot.generation)
        return HistorySubmissionResult(result)
    }
    public func settleEditing() async -> HistorySubmissionResult {
        guard !opening, !closed, !closeRequested, let engine else { return .unexecuted(failure(.busy)) }
        return HistorySubmissionResult(await engine.settleEditing())
    }
    public func reconcile() async -> HistorySubmissionResult? {
        guard !opening, !closed, !closeRequested, let engine else { return .unexecuted(failure(.busy)) }
        guard !engine.transaction.isActive else { return .unexecuted(failure(.busy)) }
        let result = await engine.transaction.reconcile { result in
            // Closure is monotonic. Keep the authoritative receipt, but do not
            // begin a presentation refresh on a retiring session.
            guard !self.closed, !self.closeRequested, self.engine === engine,
                !engine.transaction.closing, !engine.store.closing, !engine.store.closed
            else { return }
            switch result {
            case nil, .accepted:
                await engine.transaction.withHostCallback {
                    if let result { await self.nativeCoordinator.admissionCompleted(result) }
                    await self.nativeCoordinator.reconcilePresentation()
                }
            case .rejected, .failure: break
            }
        }
        refreshStatus()
        return result.map(HistorySubmissionResult.init)
    }

    public func retryDraft() async -> HistorySubmissionResult { await nativeCoordinator.retryDraft() }
    public func discardDraft() async -> HistorySubmissionResult { await nativeCoordinator.discardDraft() }
    public func reconcileNativeRegistrations() async throws {
        try await nativeCoordinator.reconcileNativeRegistrations()
    }

    /// Reserve in the native callback's actor turn, before another input can enter.
    func requestNativeOperation(_ kind: HistoryNativeOperation) {
        guard !opening, !closed, !closeRequested, let engine else { return }
        if kind != .settle { nativeCoordinator.prepareExplicitInverse() }
        guard case .success(let slot) = engine.transaction.reserve() else { return }
        let request: HistoryTransactionCoordinator.Request
        switch kind {
        case .settle: request = .settle
        case .undo: request = .undo(expectedGeneration: slot.generation)
        case .redo: request = .redo(expectedGeneration: slot.generation)
        }
        engine.transaction.complete(slot, request: request)
        let id = UUID()
        nativeOperations[id] = Task { @MainActor [weak self] in
            _ = await engine.transaction.result(of: slot)
            self?.nativeOperations.removeValue(forKey: id)
        }
    }
    public func waitForNativeOperations() async {
        for operation in Array(nativeOperations.values) { await operation.value }
    }

    func refuse(_ failure: HistoryFailure) {
        issue = failure
        opening = false
        refreshStatus()
    }
    func expect(_ setup: HistorySessionSetup) {
        configuration = setup.configuration
        operations = Dictionary(setup.operations.map { ($0.operation, $0) }, uniquingKeysWith: { first, _ in first })
    }
    func retireGeneration() throws {
        try nativeCoordinator.retireGeneration()
        epoch = UUID()
    }
    func matches(
        configuration: HistorySessionConfiguration, operations requested: [AnyHistoryOperation],
        lease: any HistoryHostLease
    ) -> Bool {
        self.lease === lease && self.configuration?.historyURL == configuration.historyURL
            && self.configuration?.workingIdentity == configuration.workingIdentity
            && self.configuration?.scope == configuration.scope
            && self.configuration?.journalDirectory == configuration.journalDirectory
            && requested.count == operations.count
            && requested.allSatisfy { operations[$0.operation]?.identity == $0.identity }
    }
    func failure(_ cause: HistoryFailureCause) -> HistoryFailure {
        HistoryFailure(cause, stage: .admission, disposition: .usable)
    }
    static func describe(_ error: Error, stage: HistoryFailureStage) -> HistoryFailure {
        error as? HistoryFailure
            ?? HistoryFailure(
                .storage, stage: stage,
                disposition: .suspended, underlyingDescription: String(describing: error))
    }
    private static func describeInput(_ error: Error) -> HistoryFailure {
        error as? HistoryFailure
            ?? HistoryFailure(
                .invalidInput, stage: .admission,
                disposition: .usable, underlyingDescription: String(describing: error))
    }
}
