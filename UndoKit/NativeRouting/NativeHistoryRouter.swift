// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

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

    private let manager: RoutedUndoManager
    private var snapshot = HistorySnapshot(canUndo: false, canRedo: false, isSuspended: false, hasPending: false)
    private var undoName = ""
    private var redoName = ""
    private var requestPending = false
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

    /// Rebuild menu availability from committed history. This does not invoke native
    /// registrations or mutate a host document, so attachment cannot replay an edit.
    public func update(snapshot: HistorySnapshot, undoName: String = "", redoName: String = "") {
        self.snapshot = snapshot
        self.undoName = undoName
        self.redoName = redoName
        publishBarrier()
    }

    /// Call after the host's accepted, rejected, or unresolved operation has completed.
    /// Availability stays suspended when the supplied snapshot says recovery is needed.
    public func finishInvocation(snapshot: HistorySnapshot, undoName: String = "", redoName: String = "") {
        requestPending = false
        update(snapshot: snapshot, undoName: undoName, redoName: redoName)
    }

    /// Apply the same editing barrier to a host-originated restoration transaction.
    public func beginExternalOperation() {
        requestPending = true
        publishBarrier()
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
    public var isEditingBlocked: Bool { requestPending || snapshot.isSuspended || registrationObserved }
    public var canUndo: Bool { (snapshot.canUndo || hasProvisionalEdit || queuedEdits > 0) && !isEditingBlocked }
    public var canRedo: Bool { snapshot.canRedo && !isEditingBlocked }
    public var undoActionName: String { canUndo ? undoName : "" }
    public var redoActionName: String { canRedo ? redoName : "" }
    public var provisionalActionName: String { manager.provisionalActionName }

    private func request(_ kind: HistoryDeliveryKind) {
        guard !isEditingBlocked else { return }
        guard kind == .undo ? (snapshot.canUndo || hasProvisionalEdit || queuedEdits > 0) : snapshot.canRedo else { return }
        guard settleEditing?() ?? true else { return }
        requestPending = true
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

    private func publishBarrier() { barrierChanged?(isEditingBlocked) }

    private final class RoutedUndoManager: UndoManager {
        weak var router: NativeHistoryRouter?
        private var assignedName = ""
        var provisionalActionName: String { assignedName.isEmpty ? super.undoActionName : assignedName }

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

        override func __registerUndoWithTarget(_ target: Any,
            handler: @escaping @MainActor @Sendable (Any) -> Void) {
            router?.registrationCount += 1
            super.__registerUndoWithTarget(target, handler: handler)
        }

        override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
            router?.registrationCount += 1
            super.registerUndo(withTarget: target, selector: selector, object: anObject)
        }
    }
}
