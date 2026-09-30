// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Why native semantic editing is available or requires host intervention.
public enum NativeHistoryRoutingState: Equatable, Sendable {
    /// The attached history can accept native requests, subject to Undo/Redo availability.
    case ready
    /// A native semantic request is waiting for its authoritative outcome.
    case pending
    /// The host must reconcile an uncertain history outcome.
    case suspended
    /// The host must identify an unexplained native registration.
    case registrationMismatch
    /// A new scope or generation requires explicit attachment after settling native work.
    case reattachmentRequired
}

/// Projects a scope's finalized history into native Undo presentation while preserving a
/// separate manager for provisional AppKit editing groups. The host settles editing and
/// performs the asynchronous history operation after a request is routed.
@MainActor public final class NativeHistoryRouter: NSObject {
    /// Give this manager to the native controls that edit this History Scope. Do not also
    /// assign it to NSDocument: document change counts follow finalized host outcomes.
    public let undoManager: UndoManager

    /// Return false while marked text is composing. The host should break text coalescing
    /// and submit the current native group before returning true.
    public var settleEditing: (() -> Bool)?
    public var undoRequested: (() -> Void)?
    public var redoRequested: (() -> Void)?
    /// Invoked when a top-level native group closes. The host classifies registered work,
    /// submits a semantic Command, or reports an unexplained registration.
    public var nativeGroupDidClose: ((_ actionName: String, _ registrationCount: Int) -> Void)?
    /// Apply or lift the host's semantic-editing barrier in every view of this scope.
    public var barrierChanged: ((_ blocked: Bool) -> Void)?

    /// Reports the reason for routing availability. The host supplies user-facing feedback.
    public var routingStateChanged: ((NativeHistoryRoutingState) -> Void)?
    /// True after a new identity is observed, until the host explicitly attaches it.
    public private(set) var requiresReattachment = false

    private struct Identity: Hashable {
        let scope: UUID
        let generation: UUID

        init?(_ snapshot: HistorySnapshot) {
            guard let scope = snapshot.scope, let generation = snapshot.generation else { return nil }
            self.scope = scope
            self.generation = generation
        }
    }
    private var retiredIdentities: Set<Identity> = []
    private let manager: RoutedUndoManager
    private var snapshot = HistorySnapshot(canUndo: false, canRedo: false, isSuspended: false, hasPending: false)
    private var undoName = ""
    private var redoName = ""
    /// Capture this identity synchronously when Undo/Redo is requested, and return it
    /// with the asynchronous completion. A later invocation has a different identity.
    public private(set) var pendingInvocationID: UUID?
    private var requestPending: Bool { pendingInvocationID != nil }
    private var registrationCount = 0
    private var registrationObserved = false
    private var hasProvisionalEdit = false
    private var transientRegistration = false
    private var queuedEdits = 0
    private var recognizedGroupPendingClose = false

    public override init() {
        let manager = RoutedUndoManager()
        // The durable store retains accepted history. Native registrations are kept only
        // long enough for AppKit editing/coalescing and must not grow with the document.
        manager.levelsOfUndo = 1
        self.manager = manager
        undoManager = manager
        super.init()
        manager.router = self
        NotificationCenter.default.addObserver(self, selector: #selector(groupDidClose(_:)),
            name: .NSUndoManagerDidCloseUndoGroup, object: manager)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Whether explicit attachment can replace native presentation without losing unsettled work.
    /// Settle provisional groups and await queued operations before attempting a reset or scope switch.
    public var canAttach: Bool {
        !requestPending && !snapshot.hasPending && !hasProvisionalEdit && queuedEdits == 0
            && !registrationObserved && registrationCount == 0 && manager.groupingLevel == 0
    }

    /// Attaches a host-confirmed scope/generation after opening or an explicit history reset.
    /// Clears only settled native registrations; it never applies a domain edit.
    /// - Throws: An invalid identity, or busy while provisional, queued, mismatched or active work remains.
    /// The host must disconnect the previous engine's callbacks. Use a new router when reopening
    /// the same generation with a new engine whose availability version starts over.
    public func attach(snapshot: HistorySnapshot, undoName: String = "", redoName: String = "") throws {
        guard let identity = Identity(snapshot) else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        guard canAttach else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        if let previous = Identity(self.snapshot), previous != identity {
            retiredIdentities.insert(previous)
        }
        retiredIdentities.remove(identity)
        manager.clearProjection()
        transientRegistration = false
        recognizedGroupPendingClose = false
        requiresReattachment = false
        self.snapshot = snapshot
        self.undoName = undoName
        self.redoName = redoName
        publishBarrier()
    }

    /// Rebuild menu availability from committed history. This does not invoke native
    /// registrations or mutate a host document, so attachment cannot replay an edit.
    /// The first identity binds automatically. Later identities require explicit `attach`;
    /// older versions and callbacks from retired identities are ignored.
    public func update(snapshot: HistorySnapshot, undoName: String = "", redoName: String = "") {
        guard accepts(snapshot) else { return }
        self.snapshot = snapshot
        self.undoName = undoName
        self.redoName = redoName
        publishBarrier()
    }

    /// Call after the host's accepted, rejected, or unresolved operation has completed.
    /// Availability stays suspended when the supplied snapshot says recovery is needed.
    /// Supply the identity captured when the invocation began. A duplicate completion,
    /// stale identity, or stale version cannot finish another invocation or lift its barrier.
    public func finishInvocation(_ invocation: UUID, snapshot: HistorySnapshot,
                                 undoName: String = "", redoName: String = "") {
        guard pendingInvocationID == invocation, accepts(snapshot) else { return }
        pendingInvocationID = nil
        update(snapshot: snapshot, undoName: undoName, redoName: redoName)
    }

    /// Apply the editing barrier to a host-originated restoration or maintenance operation.
    /// Returns its completion identity, or nil if a native operation is already pending.
    /// Capture the returned identity before starting asynchronous work.
    @discardableResult public func beginExternalOperation() -> UUID? {
        guard !requestPending else { return nil }
        let invocation = UUID()
        pendingInvocationID = invocation
        publishBarrier()
        return invocation
    }

    /// Pause semantic Undo/Redo after an unexplained native registration. The host can
    /// reconcile its source and explicitly resume without discarding user data.
    public func reportUnknownRegistration() {
        registrationObserved = true
        publishBarrier()
    }

    public func reconcileRegistrations() {
        registrationObserved = false
        publishBarrier()
    }

    /// Call when a native control has changed provisional semantic content. A first
    /// typing group may then enable Undo before its asynchronous submission finalizes.
    public func noteProvisionalEdit() { hasProvisionalEdit = true }

    /// A known editor-only registration, such as typing attributes with no authored
    /// text yet, has no semantic Command to submit.
    public func noteTransientRegistration() { transientRegistration = true }

    /// Call after the host has settled and submitted a native group. Its native
    /// registration is no longer the source of semantic Undo eligibility.
    public func didSettleProvisionalEdit() {
        hasProvisionalEdit = false
        if registrationCount > 0 { transientRegistration = true }
    }

    /// A submitted native group remains eligible for an immediately following Undo
    /// while its accepted outcome is still being finalized in the ordered queue.
    public func didQueueProvisionalEdit() {
        hasProvisionalEdit = false
        queuedEdits += 1
        if registrationCount > 0 { recognizedGroupPendingClose = true }
    }

    public func didFinishQueuedEdit() { queuedEdits = max(0, queuedEdits - 1) }

    public var hasRegistrationMismatch: Bool { registrationObserved }
    public var isEditingBlocked: Bool {
        requestPending || snapshot.isSuspended || registrationObserved || requiresReattachment
    }
    public var canUndo: Bool {
        (snapshot.canUndo || hasProvisionalEdit || queuedEdits > 0) && !isEditingBlocked
    }
    public var canRedo: Bool { snapshot.canRedo && !isEditingBlocked }
    public var undoActionName: String { canUndo ? undoName : "" }
    public var redoActionName: String { canRedo ? redoName : "" }
    public var provisionalActionName: String { manager.provisionalActionName }

    private func request(_ kind: HistoryDeliveryKind) {
        guard !isEditingBlocked else { return }
        guard kind == .undo
            ? (snapshot.canUndo || hasProvisionalEdit || queuedEdits > 0)
            : snapshot.canRedo else { return }
        guard settleEditing?() ?? true else { return }
        pendingInvocationID = UUID()
        publishBarrier()
        if kind == .undo { undoRequested?() } else { redoRequested?() }
    }

    @objc private func groupDidClose(_ notification: Notification) {
        // Foundation posts this notification before the closing group has fully left
        // its stack. A nested close must remain part of the enclosing user step.
        guard manager.groupingLevel <= 1 else { return }
        let count = registrationCount
        registrationCount = 0
        if count > 0 && !hasProvisionalEdit && !transientRegistration && !recognizedGroupPendingClose {
            reportUnknownRegistration()
        }
        transientRegistration = false
        recognizedGroupPendingClose = false
        nativeGroupDidClose?(manager.provisionalActionName, count)
    }

    /// The current routing condition; ordinary Undo/Redo eligibility is exposed separately.
    public var routingState: NativeHistoryRoutingState {
        if requiresReattachment { return .reattachmentRequired }
        if registrationObserved { return .registrationMismatch }
        if snapshot.isSuspended { return .suspended }
        if requestPending { return .pending }
        return .ready
    }

    private func accepts(_ candidate: HistorySnapshot) -> Bool {
        guard let current = Identity(snapshot) else { return true }
        guard let incoming = Identity(candidate) else { return false }
        guard incoming == current else {
            if !retiredIdentities.contains(incoming) {
                requiresReattachment = true
                publishBarrier()
            }
            return false
        }
        return !requiresReattachment && (candidate.version > snapshot.version || candidate == snapshot)
    }

    private func publishBarrier() {
        barrierChanged?(isEditingBlocked)
        routingStateChanged?(routingState)
    }

    private final class RoutedUndoManager: UndoManager {
        weak var router: NativeHistoryRouter?
        private var assignedName = ""
        var provisionalActionName: String { assignedName.isEmpty ? super.undoActionName : assignedName }

        func clearProjection() {
            removeAllActions()
            assignedName = ""
        }

        override var canUndo: Bool { router?.canUndo ?? false }
        override var canRedo: Bool { router?.canRedo ?? false }
        override var undoActionName: String { router?.undoActionName ?? "" }
        override var redoActionName: String { router?.redoActionName ?? "" }

        override func undo() { router?.request(.undo) }
        override func redo() { router?.request(.redo) }

        override func setActionName(_ actionName: String) {
            assignedName = actionName
            super.setActionName(actionName)
        }

        override func __registerUndoWithTarget(
            _ target: Any,
            handler: @escaping @MainActor @Sendable (Any) -> Void
        ) {
            router?.registrationCount += 1
            super.__registerUndoWithTarget(target, handler: handler)
        }

        override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
            router?.registrationCount += 1
            super.registerUndo(withTarget: target, selector: selector, object: anObject)
        }
    }
}
