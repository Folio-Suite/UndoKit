// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

#if canImport(AppKit)
import AppKit

/// AppKit presentation attachment. The session collection remains the recovery owner.
@MainActor public final class NativeHistoryAppKitBinding<Lease: NativeHistoryLease> {
    let session: NativeHistorySession<Lease>
    var controls: [AppKitHistoryControl] = []
    var localControls: [AppKitHistoryControl] = []
    var connection: NativeHistoryConnection?
    var capture: (() -> NativeDraftCapture<Lease.Draft>?)?
    var present: ((Lease.Draft) -> Void)?
    var presentStatus: ((NativeHistoryStatus) -> Void)?
    var observers: [NSObjectProtocol] = []
    var pending = false
    var disconnected = false
    var rendering = false
    var liveTransaction = false
    var deferredBoundary = false
    var participants: Set<ObjectIdentifier> = []
    public private(set) var lastResult: HistoryResult?
    public var isAvailable = true { didSet { publishAvailability() } }
    let actionName: String
    let liveManager = UndoManager()
    var operation: Task<HistoryResult, Never>?
    lazy var documentFacade = AppKitHistoryUndoManager(owner: self, registrationManager: liveManager, unknownManager: session.undoManager)
    public var undoManager: UndoManager { documentFacade }
    public var status: NativeHistoryStatus { session.status }
    public var hasLiveTransaction: Bool { liveTransaction }

    init<Owner: AnyObject>(session: NativeHistorySession<Lease>, owner: Owner,
        editors: [NativeHistoryAppKitTextView], localEditors: [NativeHistoryAppKitTextView],
        actionName: String, captureDraft: @escaping @MainActor (Owner) -> NativeDraftCapture<Lease.Draft>?,
        draftDidChange: @escaping @MainActor (Owner, Lease.Draft) -> Void,
        statusDidChange: (@MainActor (Owner, NativeHistoryStatus) -> Void)?) throws {
        self.session = session; self.actionName = actionName
        guard !editors.isEmpty, Set(editors.map(ObjectIdentifier.init)).count == editors.count,
              Set(localEditors.map(ObjectIdentifier.init)).count == localEditors.count,
              !localEditors.contains(where: { local in editors.contains(where: { $0 === local }) }),
              (editors + localEditors).allSatisfy({ $0.historyFacade == nil }) else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        capture = { [weak owner] in owner.flatMap(captureDraft) }
        present = { [weak owner] value in if let owner { draftDidChange(owner, value) } }
        presentStatus = { [weak owner] value in if let owner { statusDidChange?(owner, value) } }
        liveManager.levelsOfUndo = 0
        connection = try session.connect(owner: self, captureDraft: { $0.capture?() },
            draftDidChange: { $0.render($1) }, statusDidChange: { $0.statusChanged($1) })
        for editor in editors {
            let control = AppKitHistoryControl(editor: editor, registrationManager: liveManager)
            let facade = AppKitHistoryUndoManager(owner: self, editor: editor, registrationManager: liveManager, unknownManager: session.undoManager)
            control.facade = facade; editor.historyFacade = facade; editor.editingAdmission = self; controls.append(control)
        }
        for editor in localEditors {
            let manager = UndoManager()
            let control = AppKitHistoryControl(editor: editor, registrationManager: manager, isLocal: true)
            let facade = AppKitHistoryUndoManager(owner: self, editor: editor, registrationManager: manager)
            control.facade = facade; editor.historyFacade = facade; localControls.append(control)
        }
        session.editing.settlementDidComplete = { [weak self] in self?.retireAcceptedLiveHistory() }
        observeEditors(); publishAvailability()
    }

    public var permitsEditing: Bool {
        isAvailable && !pending && !disconnected && session.editing.permitsKnownLiveEditing
    }
    var hasMarkedText: Bool { controls.contains { $0.editor?.hasMarkedText() == true } }

    func captureLive() {
        guard !rendering, !disconnected, let value = capture?(), session.editing.permitsKnownLiveEditing else { return }
        do { try session.editing.captureKnownLiveDraft(value) } catch { publishAvailability() }
    }
    func render(_ value: Lease.Draft) {
        guard !disconnected else { return }
        rendering = true; present?(value); rendering = false
    }
    func statusChanged(_ value: NativeHistoryStatus) {
        guard !disconnected else { return }
        presentStatus?(value); publishAvailability()
    }

    /// An explicit boundary that persists the current AppKit editing transaction.
    @discardableResult public func commit() async -> HistoryResult {
        await perform { await $0.editing.commitKnownLiveDraft() }
    }
    /// Applies one host-declared semantic edit after settling the current text transaction.
    @discardableResult public func applyDraft(_ proposed: Lease.Draft) async -> HistoryResult {
        let present = present
        return await perform { session in
            let prior = await session.editing.commitKnownLiveDraft()
            guard session.status.phase == .ready, !session.status.requiresDraftDecision else { return prior }
            do { try session.updateDraft(proposed) }
            catch { return .failure(error as? HistoryFailure ?? HistoryFailure(.storage, stage: .preparation, disposition: .suspended)) }
            present?(proposed)
            return await session.commit()
        }
    }
    @discardableResult public func undoDocument() async -> HistoryResult {
        await perform { session in
            await session.editing.undoKnownLiveDraft()
        }
    }
    @discardableResult public func redoDocument() async -> HistoryResult {
        await perform { session in
            await session.editing.redoKnownLiveDraft()
        }
    }
    @discardableResult public func retryDraft() async -> HistoryResult { await perform { await $0.retryDraft() } }
    @discardableResult public func discardDraft() async -> HistoryResult {
        let result = await perform { await $0.discardDraft() }
        if session.status.phase == .ready, !session.status.requiresDraftDecision { retireAcceptedLiveHistory() }
        return result
    }
    #if DEBUG
    @discardableResult public func demonstrateFinalizationFailure() async -> HistoryResult {
        await perform { await $0.demonstrateFinalizationFailure() }
    }
    #endif
    public func waitForOperations() async { _ = await operation?.value }

    /// Captures and journals current presentation before releasing any AppKit callbacks.
    public func disconnect() {
        guard !disconnected else { return }
        captureLive(); disconnected = true
        connection?.disconnect(); connection = nil
        session.editing.settlementDidComplete = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        for control in controls + localControls {
            if let editor = control.editor, editor.historyFacade === control.facade {
                editor.breakUndoCoalescing(); editor.historyFacade = nil; editor.editingAdmission = nil
            }
            control.facade?.owner = nil
        }
        liveManager.removeAllActions()
        controls = []; localControls = []; capture = nil; present = nil; presentStatus = nil
    }
    public func close() async {
        captureLive(); isAvailable = false; await waitForOperations(); await session.close()
    }

    func undoManager(for editor: NativeHistoryAppKitTextView?) -> UndoManager? {
        let selected = editor ?? (controls + localControls).compactMap(\.editor).first(where: { $0.window?.firstResponder === $0 })
        if let local = localControls.first(where: { $0.editor === selected }) { return local.registrationManager }
        guard permitsEditing, !hasMarkedText else { return nil }
        if liveTransaction { return liveManager }
        return session.undoManager
    }
    func canUndo(for editor: NativeHistoryAppKitTextView?) -> Bool { return undoManager(for: editor)?.canUndo ?? false }
    func canRedo(for editor: NativeHistoryAppKitTextView?) -> Bool { undoManager(for: editor)?.canRedo ?? false }
    func name(for editor: NativeHistoryAppKitTextView?, undo: Bool) -> String {
        guard let manager = undoManager(for: editor) else { return "" }
        if manager === session.undoManager { return actionName }
        return undo ? manager.undoActionName : manager.redoActionName
    }
    func invoke(for editor: NativeHistoryAppKitTextView?, undo: Bool) {
        guard let manager = undoManager(for: editor), undo ? manager.canUndo : manager.canRedo else { return }
        if manager === session.undoManager {
            let task = start { undo ? await $0.undo() : await $0.redo() }
            _ = task
        } else {
            undo ? manager.undo() : manager.redo()
            captureLive(); publishAvailability()
        }
    }

    @discardableResult func start(_ action: @escaping @MainActor (NativeHistorySession<Lease>) async -> HistoryResult) -> Task<HistoryResult, Never>? {
        guard !pending, !disconnected, isAvailable, !hasMarkedText else { return nil }
        captureLive(); pending = true; publishAvailability()
        let session = session
        let task = Task { @MainActor [weak self, session] in
            let result = await action(session)
            guard let self, !self.disconnected else { return result }
            self.lastResult = result; self.pending = false; self.publishAvailability()
            return result
        }
        operation = task; return task
    }
    func perform(_ action: @escaping @MainActor (NativeHistorySession<Lease>) async -> HistoryResult) async -> HistoryResult {
        guard let task = start(action) else { return .failure(HistoryFailure(.busy, stage: .admission, disposition: .usable)) }
        return await task.value
    }
    @discardableResult public func settleEditing() -> Bool {
        guard !hasMarkedText else { deferredBoundary = true; publishAvailability(); return false }
        deferredBoundary = false
        guard liveTransaction else { return true }
        guard let task = start({ await $0.editing.commitKnownLiveDraft() }) else { return false }
        operation = task
        return true
    }
    func retireAcceptedLiveHistory() {
        guard !disconnected else { return }
        controls.compactMap(\.editor).forEach { $0.breakUndoCoalescing() }
        liveManager.removeAllActions(); liveTransaction = false; deferredBoundary = false; participants = []
        publishAvailability()
    }
    func publishAvailability() {
        guard !disconnected else { return }
        presentStatus?(session.status)
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: documentFacade)
        for control in controls + localControls {
            guard let editor = control.editor, let facade = control.facade else { continue }
            let signature = "\(facade.canUndo)|\(facade.canRedo)|\(facade.undoActionName)|\(facade.redoActionName)"
            guard signature != control.lastAvailability else { continue }
            control.lastAvailability = signature
            NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: facade)
            if control.isLocal { continue }
            // Refresh the native Edit menu after asynchronous acceptance without changing focus.
            NSApp.mainMenu?.update()
            _ = editor
        }
    }
    func observeEditors() {
        let names: [Notification.Name] = [NSText.didChangeNotification, NSText.didBeginEditingNotification,
            NSText.didEndEditingNotification, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let identity = note.object.map { ObjectIdentifier($0 as AnyObject) }
                let name = note.name
                MainActor.assumeIsolated {
                    guard let self, !self.disconnected else { return }
                    if identity == ObjectIdentifier(self.liveManager) {
                        NotificationCenter.default.post(name: name, object: self.documentFacade)
                        self.publishAvailability(); return
                    }
                    guard let editor = self.controls.compactMap(\.editor).first(where: { ObjectIdentifier($0) == identity }) else { return }
                    if self.localControls.contains(where: { $0.editor === editor }) { return }
                    switch name {
                    case NSText.didChangeNotification:
                        self.liveTransaction = true; self.participants.insert(ObjectIdentifier(editor)); self.captureLive()
                    case NSText.didBeginEditingNotification:
                        if self.liveTransaction, !self.participants.contains(ObjectIdentifier(editor)) { _ = self.settleEditing() }
                    case NSText.didEndEditingNotification:
                        if self.liveTransaction { _ = self.settleEditing() }
                    default:
                        NotificationCenter.default.post(name: name, object: self.documentFacade)
                    }
                    if self.deferredBoundary, !self.hasMarkedText { _ = self.settleEditing() }
                    self.publishAvailability()
                }
            })
        }
    }
    isolated deinit { disconnect() }
}

@MainActor final class AppKitHistoryControl {
    weak var editor: NativeHistoryAppKitTextView?
    let registrationManager: UndoManager
    let isLocal: Bool
    var facade: AppKitHistoryUndoManager?
    var lastAvailability = ""
    init(editor: NativeHistoryAppKitTextView, registrationManager: UndoManager, isLocal: Bool = false) {
        self.editor = editor; self.registrationManager = registrationManager; self.isLocal = isLocal
    }
}

@MainActor final class AppKitHistoryUndoManager: UndoManager {
    weak var owner: NativeHistoryAppKitBindingMarker?
    weak var editor: NativeHistoryAppKitTextView?
    let registrationManager: UndoManager
    let unknownManager: UndoManager?
    init(owner: any NativeHistoryAppKitBindingMarker, editor: NativeHistoryAppKitTextView? = nil,
        registrationManager: UndoManager, unknownManager: UndoManager? = nil) {
        self.owner = owner; self.editor = editor; self.registrationManager = registrationManager
        self.unknownManager = unknownManager; super.init()
    }
    func destination(for target: Any) -> UndoManager {
        // NSTextView's documented Undo support registers text-storage operations. Only
        // these exact bound objects belong to the disposable live transaction.
        if unknownManager == nil || owner?.appKitRecognizes(target: target) == true { return registrationManager }
        return unknownManager!
    }
    override var groupsByEvent: Bool {
        get { registrationManager.groupsByEvent } set { registrationManager.groupsByEvent = newValue }
    }
    override var groupingLevel: Int { registrationManager.groupingLevel }
    override var isUndoing: Bool { registrationManager.isUndoing }
    override var isRedoing: Bool { registrationManager.isRedoing }
    override var isUndoRegistrationEnabled: Bool { registrationManager.isUndoRegistrationEnabled }
    override var levelsOfUndo: Int {
        get { registrationManager.levelsOfUndo } set { registrationManager.levelsOfUndo = newValue }
    }
    override var runLoopModes: [RunLoop.Mode] {
        get { registrationManager.runLoopModes } set { registrationManager.runLoopModes = newValue }
    }
    override func beginUndoGrouping() { registrationManager.beginUndoGrouping() }
    override func endUndoGrouping() { registrationManager.endUndoGrouping() }
    override func disableUndoRegistration() { registrationManager.disableUndoRegistration() }
    override func enableUndoRegistration() { registrationManager.enableUndoRegistration() }
    override func setActionName(_ actionName: String) { registrationManager.setActionName(actionName) }
    override func removeAllActions() { registrationManager.removeAllActions() }
    override func removeAllActions(withTarget target: Any) { registrationManager.removeAllActions(withTarget: target) }
    override func prepare(withInvocationTarget target: Any) -> Any { destination(for: target).prepare(withInvocationTarget: target) }
    override var canUndo: Bool { owner?.appKitCanUndo(for: editor) ?? false }
    override var canRedo: Bool { owner?.appKitCanRedo(for: editor) ?? false }
    override var undoActionName: String { owner?.appKitName(for: editor, undo: true) ?? "" }
    override var redoActionName: String { owner?.appKitName(for: editor, undo: false) ?? "" }
    override func undo() { owner?.appKitInvoke(for: editor, undo: true) }
    override func redo() { owner?.appKitInvoke(for: editor, undo: false) }
    override func __registerUndoWithTarget(_ target: Any, handler: @escaping @MainActor @Sendable (Any) -> Void) {
        destination(for: target).__registerUndoWithTarget(target, handler: handler)
    }
    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        destination(for: target).registerUndo(withTarget: target, selector: selector, object: anObject)
    }
}

@MainActor protocol NativeHistoryAppKitBindingMarker: AnyObject {
    func appKitRecognizes(target: Any) -> Bool
    func appKitCanUndo(for editor: NativeHistoryAppKitTextView?) -> Bool
    func appKitCanRedo(for editor: NativeHistoryAppKitTextView?) -> Bool
    func appKitName(for editor: NativeHistoryAppKitTextView?, undo: Bool) -> String
    func appKitInvoke(for editor: NativeHistoryAppKitTextView?, undo: Bool)
}

extension NativeHistoryAppKitBinding: NativeHistoryAppKitBindingMarker, AppKitEditingAdmission {
    func admitChange(in editor: NativeHistoryAppKitTextView) -> Bool {
        guard permitsEditing else { return false }
        liveTransaction = true; participants.insert(ObjectIdentifier(editor)); return true
    }
    func appKitRecognizes(target: Any) -> Bool {
        controls.contains { control in
            guard let editor = control.editor else { return false }
            return target as AnyObject === editor || target as AnyObject === editor.textStorage
        }
    }
    func appKitCanUndo(for editor: NativeHistoryAppKitTextView?) -> Bool { canUndo(for: editor) }
    func appKitCanRedo(for editor: NativeHistoryAppKitTextView?) -> Bool { canRedo(for: editor) }
    func appKitName(for editor: NativeHistoryAppKitTextView?, undo: Bool) -> String { name(for: editor, undo: undo) }
    func appKitInvoke(for editor: NativeHistoryAppKitTextView?, undo: Bool) { invoke(for: editor, undo: undo) }
}
#endif
