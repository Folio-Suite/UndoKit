// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Safe native editing, durable submission and complete lease closure behind one interface.
/// Do not submit directly to the lease's engine while this session owns it.
@MainActor final class NativeEditingSession<Lease: NativeHistoryLease>: NativeSessionUndoOwner {
    let documentURL: URL
    let undoManager: UndoManager
    private(set) var draft: Lease.Draft?
    var statusDidChange: ((NativeHistoryStatus) -> Void)?
    private(set) var status = NativeHistoryStatus(phase: .opening, canUndo: false, canRedo: false, issue: nil, requiresDraftDecision: false)
    private(set) var hasConnection = false
    var ownerChanged: (() -> Void)?
    private let lease: Lease
    private let codec: HistoryCodec<Lease.Draft>
    private let codecVersion: Int
    private let draftURL: URL
    private var base: NativeDraftSnapshot<Lease.Draft>?
    private var composing = false
    private var unexplainedNativeRegistration = false
    private var epoch = UUID()
    private struct Binding: Equatable {
        let scope: UUID
        let generation: UUID
        let working: UUID
        @MainActor init(_ engine: HistoryEngine) throws {
            guard let scope = engine.snapshot.scope, let generation = engine.snapshot.generation else {
                throw HistoryFailure(.invalidInput, stage: .admission, disposition: .suspended)
            }
            self.scope = scope; self.generation = generation; working = engine.store.workingIdentity
        }
    }
    private var binding: Binding?
    private var needsReopen = false
    private var capture: (() -> NativeDraftCapture<Lease.Draft>?)?
    private var present: ((Lease.Draft) -> Void)?
    private var presentStatus: ((NativeHistoryStatus) -> Void)?
    private var connectionID: UUID?
    private var nativeTask: Task<Void, Never>?
    private var operationFinished: [CheckedContinuation<Void, Never>] = []
    private var closing = false
    private var closeFinished: [CheckedContinuation<Void, Never>] = []
    private var phase: NativeHistoryPhase = .opening
    private var issue: HistoryFailure?
    private var requiresDecision = false
    private var journalDirty = false
    private var journalCompatible = true
    private var prepared: HistoryCommand?
    private var provedRejected = false
    private var proposedRevision = UUID().uuidString.data(using: .utf8)!
    private let manager: NativeSessionUndoManager

    init(documentURL: URL, lease: Lease, codec: HistoryCodec<Lease.Draft>, codecVersion: Int, draftURL: URL) {
        self.documentURL = documentURL; self.lease = lease; self.codec = codec
        self.codecVersion = codecVersion; self.draftURL = draftURL
        let manager = NativeSessionUndoManager(); self.manager = manager; undoManager = manager
        manager.owner = self; manager.levelsOfUndo = 1
    }
    func open(_ mode: NativeHistoryOpenMode) async {
        epoch = UUID(); phase = .opening; issue = nil; closing = false; publish()
        defer { let waiters = operationFinished; operationFinished = []; waiters.forEach { $0.resume() } }
        do {
            try await lease.open(mode)
            guard let engine = lease.history else { throw failure(.invalidInput) }
            binding = try Binding(engine); needsReopen = false
            let attachedEpoch = epoch
            engine.snapshotDidChange = { [weak self] _ in
                guard let self, self.epoch == attachedEpoch else { return }; self.publish()
            }
            base = try await lease.readDraft(); draft = base?.value
            composing = false; prepared = nil; provedRejected = false; requiresDecision = false
            try restoreJournal()
            phase = engine.snapshot.isSuspended ? .suspended : .ready
            publish()
        } catch { block(error) }
    }
    /// The session stores a weak presentation owner; callbacks receive it as an argument.
    func connect<Owner: AnyObject>(owner: Owner,
        captureDraft: @escaping @MainActor (Owner) -> NativeDraftCapture<Lease.Draft>?,
        draftDidChange: @escaping @MainActor (Owner, Lease.Draft) -> Void,
        statusDidChange: (@MainActor (Owner, NativeHistoryStatus) -> Void)? = nil) throws -> NativeHistoryConnection {
        guard !hasConnection, phase != .closing else { throw failure(.busy) }
        let id = UUID(); connectionID = id; hasConnection = true
        capture = { [weak owner] in owner.flatMap(captureDraft) }
        present = { [weak owner] value in if let owner { draftDidChange(owner, value) } }
        presentStatus = { [weak owner] status in if let owner { statusDidChange?(owner, status) } }
        if let draft { present?(draft) }; publish()
        return NativeHistoryConnection { [weak self] in
            guard let self, self.connectionID == id else { return }
            if self.phase == .ready, !self.closing, !self.requiresDecision, let captured = self.capture?() {
                // Capture values while the weak presenter is still available. Failed persistence
                // leaves values and complete lease ownership in the collection's blocked session.
                do { try self.updateDraft(captured.value, isComposing: captured.isComposing) } catch { }
            }
            self.capture = nil; self.present = nil; self.presentStatus = nil
            self.connectionID = nil; self.hasConnection = false
            if !self.unexplainedNativeRegistration { self.manager.removeAllActions() }
            self.publish()
        }
    }
    func updateDraft(_ proposed: Lease.Draft, isComposing: Bool = false) throws {
        guard phase == .ready, !closing, !requiresDecision else { throw failure(.busy) }
        draft = proposed; composing = isComposing; journalDirty = true
        proposedRevision = Data(UUID().uuidString.utf8)
        do { try persistDraft() } catch { block(error); throw error }
        publish()
    }
    func submit(_ command: HistoryCommand) async -> HistoryResult {
        guard draft == base?.value, prepared == nil, !composing else { return .failure(failure(.busy)) }
        guard admit() else { return .failure(failure(.busy)) }
        defer { finish() }
        guard let engine = lease.history else { return .failure(failure(.missingHistory)) }
        let result = await engine.submit(command)
        await refresh(after: result)
        return result
    }
    func commit() async -> HistoryResult {
        guard captureCurrent(), admit() else { return .failure(failure(.busy)) }
        defer { finish() }
        return await commitAdmitted()
    }
    #if DEBUG
    func demonstrateFinalizationFailure() async -> HistoryResult {
        guard captureCurrent(), admit() else { return .failure(failure(.busy)) }
        defer { finish() }
        return await commitAdmitted(injectFinalizationFailure: true)
    }
    #endif
    func retryDraft() async -> HistoryResult {
        guard journalCompatible, phase == .ready || phase == .suspended || (phase == .blocked && base != nil) else { return .failure(failure(.busy)) }
        guard !closing, !unexplainedNativeRegistration else { return .failure(nativeRegistrationFailure()) }
        requiresDecision = false; composing = false
        if provedRejected { prepared = nil; provedRejected = false }
        phase = .busy; issue = nil; publish(); defer { finish() }
        if needsReopen {
            do { try await reopenLease() } catch { block(error); return .failure(issue!) }
        }
        if let engine = lease.history, engine.snapshot.isSuspended {
            if let result = await engine.reconcile(), case .failure(let failure) = result {
                guard failure.cause == .storage else { await refresh(after: result); return result }
                do {
                    // A refused persistence context requires a fresh existing-only attachment.
                    needsReopen = true
                    try await reopenLease()
                } catch { block(error); return .failure(issue!) }
            }
        }
        return await commitAdmitted()
    }
    func discardDraft() async -> HistoryResult {
        guard !unexplainedNativeRegistration else { return .failure(nativeRegistrationFailure()) }
        guard journalCompatible else { return .failure(HistoryFailure(.compatibility, stage: .preparation, disposition: .suspended)) }
        guard !closing, phase == .ready || (phase == .blocked && lease.history != nil) else { return .failure(failure(.busy)) }
        guard prepared == nil || provedRejected else { return .failure(failure(.unresolved)) }
        phase = .busy; publish(); defer { finish() }
        do { try removeJournal(); base = try await lease.readDraft(); draft = base?.value; composing = false; requiresDecision = false; prepared = nil; provedRejected = false
            if let draft { present?(draft) }; return .rejected
        } catch { block(error); return .failure(issue!) }
    }
    func undo() async -> HistoryResult {
        guard captureCurrent(), admit() else { return .failure(failure(.busy)) }
        defer { finish() }
        return await inverseAdmitted(undo: true)
    }
    func redo() async -> HistoryResult {
        guard captureCurrent(), admit() else { return .failure(failure(.busy)) }
        defer { finish() }
        return await inverseAdmitted(undo: false)
    }
    func close() async {
        guard !unexplainedNativeRegistration else { publish(); return }
        if phase == .closed { return }
        if closing { await withCheckedContinuation { closeFinished.append($0) }; return }
        if phase == .ready, !requiresDecision, let captured = capture?() {
            do { try updateDraft(captured.value, isComposing: captured.isComposing) } catch { return }
        }
        if journalDirty { do { try persistDraft() } catch { block(error); return } }
        closing = true; publish()
        defer { let waiters = closeFinished; closeFinished = []; waiters.forEach { $0.resume() } }
        if phase == .busy || phase == .opening { await withCheckedContinuation { operationFinished.append($0) } }
        phase = .closing; publish()
        if journalDirty { do { try persistDraft() } catch { closing = false; block(error); return } }
        do { try await lease.close(); manager.removeAllActions(); epoch = UUID(); phase = .closed; issue = nil; closing = false; publish() }
        catch { closing = false; needsReopen = true; block(error) }
    }
    private func reopenLease() async throws {
        guard let binding else { throw failure(.missingHistory) }
        try persistDraft()
        epoch = UUID()
        try await lease.close()
        try await lease.open(.existing)
        guard let reopened = lease.history, try Binding(reopened) == binding else {
            throw HistoryFailure(.identityConflict, stage: .reconciliation, disposition: .suspended)
        }
        let attachedEpoch = epoch
        reopened.snapshotDidChange = { [weak self] _ in
            guard let self, self.epoch == attachedEpoch else { return }; self.publish()
        }
        needsReopen = false
    }
    private func commitAdmitted(injectFinalizationFailure: Bool = false) async -> HistoryResult {
        guard !composing, let base, let proposed = draft, let engine = lease.history,
              let generation = engine.snapshot.generation else { return .failure(failure(.busy)) }
        do {
            if prepared == nil {
                guard try await lease.readDraft() == base else { throw HistoryFailure(.identityConflict, stage: .preparation, disposition: .suspended) }
                guard let command = try await lease.makeCommand(from: base, to: proposed, generation: generation) else {
                    try removeJournal()
                    draft = base.value; composing = false; requiresDecision = false
                    if let draft { present?(draft) }
                    return .rejected
                }
                prepared = command
            }
            try persistDraft()
            let result: HistoryResult
            #if DEBUG
            result = injectFinalizationFailure ? await engine.submitWithInjectedFinalizationFailure(prepared!) : await engine.submit(prepared!)
            #else
            result = await engine.submit(prepared!)
            #endif
            if case .rejected = result { provedRejected = true; requiresDecision = true; try persistDraft() }
            await refresh(after: result); return result
        } catch { block(error); return .failure(issue!) }
    }
    private func inverseAdmitted(undo: Bool) async -> HistoryResult {
        guard let engine = lease.history else { return .failure(failure(.missingHistory)) }
        if draft != base?.value {
            let result = await commitAdmitted()
            guard case .accepted = result else { return result }
            guard phase == .busy, !unexplainedNativeRegistration else {
                return .failure(unexplainedNativeRegistration ? nativeRegistrationFailure() : (issue ?? failure(.unresolved)))
            }
        }
        let result = undo ? await engine.undo(expectedGeneration: engine.snapshot.generation)
                          : await engine.redo(expectedGeneration: engine.snapshot.generation)
        await refresh(after: result); return result
    }
    private func refresh(after result: HistoryResult) async {
        if case .accepted = result {
            do { let refreshed = try await lease.readDraft(); try removeJournal()
                base = refreshed; draft = refreshed.value; composing = false
                prepared = nil; provedRejected = false; requiresDecision = false
                if !unexplainedNativeRegistration { manager.removeAllActions() }
                if let draft { present?(draft) }
            } catch { block(error) }
        } else if case .failure(let failure) = result { issue = failure }
    }
    private func persistDraft() throws {
        journalDirty = true
        guard let base, let proposed = draft, let engine = lease.history,
              let scope = engine.snapshot.scope, let generation = engine.snapshot.generation else { throw failure(.missingHistory) }
        if proposed == base.value && !composing && prepared == nil { try removeJournal(); return }
        let journal = NativeDraftJournal(scope: scope, workingIdentity: engine.store.workingIdentity,
            generation: generation, codec: codec.identifier, configuration: codec.configuration,
            version: codecVersion, base: try codec.encode(base.value), baseRevision: base.revision,
            proposed: try codec.encode(proposed), proposedRevision: proposedRevision, composing: composing,
            prepared: prepared.map(NativeDraftJournal.Command.init), rejected: provedRejected)
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #else
        let options: Data.WritingOptions = .atomic
        #endif
        try JSONEncoder().encode(journal).write(to: draftURL, options: options)
        journalDirty = false
    }
    private func restoreJournal() throws {
        guard FileManager.default.fileExists(atPath: draftURL.path), let engine = lease.history else { return }
        journalCompatible = false
        let journal = try JSONDecoder().decode(NativeDraftJournal.self, from: Data(contentsOf: draftURL))
        guard journal.format == 1, journal.scope == engine.snapshot.scope,
              journal.workingIdentity == engine.store.workingIdentity, journal.generation == engine.snapshot.generation,
              journal.codec == codec.identifier, journal.configuration == codec.configuration,
              journal.version == codecVersion else {
            throw HistoryFailure(.compatibility, stage: .preparation, disposition: .suspended)
        }
        base = NativeDraftSnapshot(value: try codec.decode(journal.base), revision: journal.baseRevision)
        draft = try codec.decode(journal.proposed); composing = journal.composing
        prepared = journal.prepared?.value; provedRejected = journal.rejected
        proposedRevision = journal.proposedRevision; requiresDecision = true
        journalCompatible = true; journalDirty = false
    }
    private func removeJournal() throws {
        if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) }
        journalDirty = false
    }
    private func captureCurrent() -> Bool {
        guard phase == .ready, !closing, !requiresDecision else { return false }
        if let value = capture?() { do { try updateDraft(value.value, isComposing: value.isComposing) } catch { return false } }
        return !composing
    }
    private func admit() -> Bool {
        guard phase == .ready, !closing, !requiresDecision, !unexplainedNativeRegistration else { return false }
        phase = .busy; issue = nil; publish(); return true
    }
    private func finish() {
        if phase == .busy { phase = lease.history?.snapshot.isSuspended == true ? .suspended : .ready }
        let waiters = operationFinished; operationFinished = []; waiters.forEach { $0.resume() }; publish()
    }
    private func failure(_ cause: HistoryFailureCause) -> HistoryFailure { HistoryFailure(cause, stage: .admission, disposition: .usable) }
    private func block(_ error: Error) {
        issue = error as? HistoryFailure ?? HistoryFailure(.storage, stage: .preparation, disposition: .suspended, underlyingDescription: String(describing: error))
        phase = .blocked; publish()
    }
    private func publish() {
        let snapshot = lease.history?.snapshot
        let available = phase == .ready && !closing && !requiresDecision && !composing && !unexplainedNativeRegistration
        let publishedPhase: NativeHistoryPhase = closing ? .closing : (unexplainedNativeRegistration && phase == .ready ? .suspended : phase)
        status = NativeHistoryStatus(phase: publishedPhase,
            canUndo: available && (snapshot?.canUndo == true || draft != base?.value),
            canRedo: available && snapshot?.canRedo == true,
            issue: unexplainedNativeRegistration ? nativeRegistrationFailure() : issue, requiresDraftDecision: requiresDecision)
        statusDidChange?(status); presentStatus?(status); ownerChanged?()
    }
    private func nativeRegistrationFailure() -> HistoryFailure {
        HistoryFailure(.hostProtocol, stage: .admission, disposition: .suspended,
            underlyingDescription: "Native registrations require explicit host reconciliation")
    }
    func nativeRegistrationObserved() {
        unexplainedNativeRegistration = true
        // Preserve all unexplained groups until the host can identify their authored work.
        manager.levelsOfUndo = 0
        publish()
    }
    func reconcileNativeRegistrations() throws {
        guard phase == .ready, !closing, !requiresDecision, prepared == nil,
              lease.history?.snapshot.isSuspended == false else { throw failure(.busy) }
        guard captureCurrent() else { throw failure(.busy) }
        // The caller explicitly certifies that all native registrations have been identified
        // and their authored values reconciled. Captured values must persist before release.
        unexplainedNativeRegistration = false
        manager.removeAllActions(); manager.levelsOfUndo = 1; publish()
    }
    var nativeCanUndo: Bool { status.canUndo }
    var nativeCanRedo: Bool { status.canRedo }
    func requestNativeUndo(_ undo: Bool) {
        guard captureCurrent(), admit() else { return }
        nativeTask = Task { [self] in _ = await inverseAdmitted(undo: undo); finish(); nativeTask = nil }
    }
}

@MainActor private protocol NativeSessionUndoOwner: AnyObject {
    var nativeCanUndo: Bool { get }
    var nativeCanRedo: Bool { get }
    func requestNativeUndo(_ undo: Bool)
    func nativeRegistrationObserved()
}
@MainActor private final class NativeSessionUndoManager: UndoManager {
    weak var owner: (any NativeSessionUndoOwner)?
    override var canUndo: Bool { owner?.nativeCanUndo ?? false }
    override var canRedo: Bool { owner?.nativeCanRedo ?? false }
    override func undo() { owner?.requestNativeUndo(true) }
    override func redo() { owner?.requestNativeUndo(false) }
    override func __registerUndoWithTarget(
        _ target: Any,
        handler: @escaping @MainActor @Sendable (Any) -> Void
    ) {
        super.__registerUndoWithTarget(target, handler: handler)
        owner?.nativeRegistrationObserved()
    }
    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        super.registerUndo(withTarget: target, selector: selector, object: anObject)
        owner?.nativeRegistrationObserved()
    }
}
