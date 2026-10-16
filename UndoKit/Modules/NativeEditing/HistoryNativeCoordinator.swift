// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

@MainActor protocol HistoryNativePlatformAdapter: AnyObject {
    var attachmentID: UUID { get }
    var undoManager: UndoManager { get }
    var available: Bool { get set }
    func capture(control: UUID) -> (value: String, composing: Bool)?
    func render(field: String, value: String)
    func publishAvailability()
    func liveManager(control: UUID) -> UndoManager?
    func retire(transaction: UUID)
    func detach()
}

@MainActor final class HistoryNativeCoordinator: HistoryAdmissionParticipant {
    struct WeakAdapter {
        weak var value: (any HistoryNativePlatformAdapter)?
    }
    struct Transaction {
        let id: UUID
        let attachment: UUID
        let control: UUID
        let field: String
        let adapter: any HistoryNativePlatformAdapter
    }
    unowned let session: HistorySession
    var unboundJournals: Set<String> = []
    var fields: [String: HistoryNativeFieldState] = [:]
    var adapters: [UUID: WeakAdapter] = [:]
    var transaction: Transaction?
    var settled: [UUID: HistoryResult] = [:]
    var unknown = false
    var registrationEpoch: UInt = 0
    var closing = false
    var deferredBoundary = false
    var issue: HistoryFailure?
    var compositionWaiters: [CheckedContinuation<Void, Never>] = []
    var publishing = false
    private lazy var facade = HistorySessionUndoManager(owner: self)
    var undoManager: UndoManager { facade }
    func clearCertifiedNativeActions() { facade.removeAllActions() }
    init(session: HistorySession) { self.session = session }

    func register(_ adapter: any HistoryNativePlatformAdapter) {
        adapters[adapter.attachmentID] = WeakAdapter(value: adapter)
        refreshAvailability()
    }
    func register(_ field: HistoryField<String>) async throws -> String {
        guard field.session === session, !field.id.isEmpty, field.id.utf8.count <= 100, !field.mappingID.isEmpty,
            field.mappingID.utf8.count <= 256, field.version > 0
        else { throw failure(.invalidInput) }
        if let existing = fields[field.id] {
            guard existing.matches(field) else { throw failure(.identityConflict) }
            return existing.requiresDecision && transaction == nil ? existing.proposed : existing.base.value
        }
        guard let configuration = session.configuration, let generation = session.engine?.snapshot.generation else {
            throw failure(.missingHistory)
        }
        let directory = journalDirectory(configuration)
        let name = field.id.utf8.map { String(format: "%02x", $0) }.joined() + ".json"
        let epoch = session.epoch
        let snapshot = try await field.read()
        guard session.epoch == epoch, session.engine?.snapshot.generation == generation,
            session.status.phase != .closing, session.status.phase != .closed
        else { throw failure(.identityConflict) }
        let state = HistoryNativeFieldState(
            field, snapshot: snapshot, journalURL: directory.appendingPathComponent(name))
        // Recheck after actor-correct host reading suspends.
        if let existing = fields[field.id] {
            guard existing.matches(field) else { throw failure(.identityConflict) }
            return existing.requiresDecision && transaction == nil ? existing.proposed : existing.base.value
        }
        fields[field.id] = state
        do {
            try state.restore(configuration: configuration, generation: generation)
            unboundJournals.remove(field.id)
        } catch {
            block(error)
            throw error
        }
        refreshAvailability()
        return state.proposed
    }
    func hasLiveTransaction(attachment: UUID) -> Bool { transaction?.attachment == attachment }
    func permitsEditing(attachment: UUID, control: UUID, composing: Bool) -> Bool {
        guard !closing, !unknown, adapters[attachment]?.value?.available == true,
            let store = session.engine?.store, !store.maintenance, !store.closing, !store.closed
        else { return false }
        // A reservation must not strand existing marked input behind its own barrier.
        if let transaction, transaction.attachment == attachment, transaction.control == control,
            fields[transaction.field]?.composing == true,
            fields[transaction.field]?.requiresExplicitDecision == false, composing {
            return true
        }
        guard session.status.phase == .ready, issue == nil, unboundJournals.isEmpty,
            !session.status.requiresDraftDecision || canRetryLiveRejection
        else { return false }
        if let transaction, transaction.attachment != attachment || transaction.control != control { return false }
        return true
    }
    func beginChange(attachment: UUID, control: UUID, field: String, composing: Bool) -> Bool {
        guard permitsEditing(attachment: attachment, control: control, composing: composing), let state = fields[field],
            state.compatible
        else { return false }
        if let previous = transaction, state.rejected, settled[previous.id] != nil {
            settled.removeAll()
            transaction = Transaction(
                id: UUID(), attachment: previous.attachment, control: previous.control,
                field: previous.field, adapter: previous.adapter)
        }
        if transaction == nil {
            guard let adapter = adapters[attachment]?.value else { return false }
            settled.removeAll()
            transaction = Transaction(
                id: UUID(), attachment: attachment, control: control, field: field, adapter: adapter)
        }
        return true
    }
    func changed(attachment: UUID, control: UUID, field: String, value: String, composing: Bool) {
        guard let transaction, transaction.attachment == attachment, transaction.control == control,
            transaction.field == field,
            let state = fields[field], !state.requiresExplicitDecision
        else { return }
        state.proposed = value
        state.composing = composing
        do { try persist(state) } catch { block(error) }
        if !composing {
            resumeComposition()
            if deferredBoundary {
                deferredBoundary = false
                session.requestNativeOperation(.settle)
            }
        }
        refreshAvailability()
    }
    func focusBoundary(attachment: UUID, beginningControl: UUID? = nil) {
        guard adapters[attachment]?.value != nil, let transaction else { return }
        if transaction.attachment == attachment, transaction.control == beginningControl { return }
        // Native responder callbacks initiate one ordinary queue request; there is no adapter task chain.
        session.requestNativeOperation(.settle)
    }
    @discardableResult func requestSettlement(attachment: UUID) -> Bool {
        guard let adapter = adapters[attachment]?.value, adapter.available else { return false }
        if let transaction {
            guard fields[transaction.field]?.requiresExplicitDecision == false else { return false }
            // Native marked-range updates can follow the text-change notification.
            // Read the control synchronously at the requested boundary, before queue admission.
            do { try capture(transaction) } catch {
                block(error)
                return false
            }
            if fields[transaction.field]?.composing == true {
                deferredBoundary = true
                return false
            }
        }
        session.requestNativeOperation(.settle)
        return true
    }
    func compositionChanged(attachment: UUID) {
        guard let transaction, transaction.attachment == attachment else { return }
        do {
            try capture(transaction)
            if fields[transaction.field]?.composing == false {
                resumeComposition()
                if deferredBoundary {
                    deferredBoundary = false
                    session.requestNativeOperation(.settle)
                }
            }
        } catch { block(error) }
        refreshAvailability()
    }
    func publish(status: HistorySessionStatus) { refreshAvailability() }
    func refreshAvailability() {
        guard !publishing else { return }
        publishing = true
        defer { publishing = false }
        let live = transaction.flatMap { $0.adapter.liveManager(control: $0.control) }
        session.nativeStateChanged(
            issue: unknown ? failure(.hostProtocol, suspended: true) : issue,
            requiresDraftDecision: !unboundJournals.isEmpty || fields.values.contains { $0.requiresDecision },
            hasLiveUndo: live?.canUndo ?? false, hasLiveRedo: live?.canRedo ?? false)
        adapters.values.compactMap(\.value).forEach { $0.publishAvailability() }
    }
    func detach(attachment: UUID) {
        guard let adapter = adapters[attachment]?.value else { return }
        if let transaction, transaction.attachment == attachment {
            let state: HistoryNativeFieldState?
            do { state = try captureValues(transaction) } catch {
                // An unexplained value cannot replace exact prepared intent on detachment.
                block(error)
                return
            }
            state?.requiresDecision = true
            state?.liveRejectionEditable = false
            do { if let state { try persist(state) } } catch { block(error) }
            // The session retains captured values even when journaling is blocked.
            // Unexplained callbacks remain in its separate facade, never this known live stack.
            retire(transaction)
        }
        adapter.detach()
        adapters.removeValue(forKey: attachment)
        refreshAvailability()
    }
    func capture(_ transaction: Transaction) throws {
        if let state = try captureValues(transaction) { try persist(state) }
    }
    private func captureValues(_ transaction: Transaction) throws -> HistoryNativeFieldState? {
        guard let state = fields[transaction.field],
            let value = transaction.adapter.capture(control: transaction.control)
        else { return nil }
        if state.prepared != nil, !state.rejected, value.value != state.proposed {
            throw failure(.identityConflict, suspended: true)
        }
        state.proposed = value.value
        state.composing = value.composing
        return state
    }
    func persist(_ state: HistoryNativeFieldState) throws {
        guard let configuration = session.configuration, let generation = session.engine?.snapshot.generation else {
            throw failure(.missingHistory)
        }
        try state.persist(configuration: configuration, generation: generation)
    }
    func refresh(_ state: HistoryNativeFieldState) async throws {
        let authoritative = try await state.declaration.read()
        try state.removeJournal()
        state.base = authoritative
        state.proposed = authoritative.value
        state.prepared = nil
        state.rejected = false
        state.liveRejectionEditable = false
        state.composing = false
        state.requiresDecision = false
        adapters.values.compactMap(\.value).forEach {
            $0.render(field: state.declaration.id, value: authoritative.value)
        }
    }
    func retire(_ transaction: Transaction) {
        guard self.transaction?.id == transaction.id else { return }
        transaction.adapter.retire(transaction: transaction.id)
        self.transaction = nil
        deferredBoundary = false
    }
    func resumeComposition() {
        let waiters = compositionWaiters
        compositionWaiters = []
        waiters.forEach { $0.resume() }
    }
    func block(_ error: Error) {
        issue =
            error as? HistoryFailure
            ?? HistoryFailure(
                .storage, stage: .preparation, disposition: .suspended, underlyingDescription: String(describing: error)
            )
        refreshAvailability()
    }
    func failure(_ cause: HistoryFailureCause, suspended: Bool = false) -> HistoryFailure {
        HistoryFailure(cause, stage: .admission, disposition: suspended ? .suspended : .usable)
    }
}

@MainActor private final class HistorySessionUndoManager: UndoManager {
    weak var owner: HistoryNativeCoordinator?
    init(owner: HistoryNativeCoordinator) {
        self.owner = owner
        super.init()
        levelsOfUndo = 0
    }
    override var canUndo: Bool { owner?.nativeCanUndo ?? false }
    override var canRedo: Bool { owner?.nativeCanRedo ?? false }
    override func undo() { owner?.requestNativeUndo(true) }
    override func redo() { owner?.requestNativeUndo(false) }
    override func __registerUndoWithTarget(_ target: Any, handler: @escaping @MainActor @Sendable (Any) -> Void) {
        super.__registerUndoWithTarget(target, handler: handler)
        owner?.nativeRegistrationObserved()
    }
    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        super.registerUndo(withTarget: target, selector: selector, object: anObject)
        owner?.nativeRegistrationObserved()
    }
}
