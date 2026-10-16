// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

#if canImport(AppKit)
import AppKit

/// AppKit mechanics for an attachment; shared-session policy lives in HistoryNativeCoordinator.
@MainActor public final class NativeHistoryAppKitBinding: HistoryNativePlatformAdapter, AppKitEditingAdmission {
    let session: HistorySession
    let attachmentID: UUID
    private weak var attachment: HistoryAttachment?
    var controls: [AppKitHistoryControl] = []
    private var localControls: [AppKitHistoryControl] = []
    var observers: [NSObjectProtocol] = []
    let liveManager = UndoManager()
    var disconnected = false
    var rendering = false
    var available = true
    public var isAvailable: Bool {
        get { available }
        set {
            available = newValue
            publishAvailability()
        }
    }
    private lazy var documentFacade = AppKitHistoryUndoManager(
        owner: self, registrationManager: liveManager, unknownManager: session.nativeCoordinator.undoManager)
    public var undoManager: UndoManager { documentFacade }
    public var status: HistorySessionStatus { session.status }
    public var hasLiveTransaction: Bool { session.nativeCoordinator.hasLiveTransaction(attachment: attachmentID) }
    public private(set) var lastResult: HistorySubmissionResult?
    public var permitsEditing: Bool {
        available && !disconnected && !session.status.isEditingBlocked
    }
    init(attachment: HistoryAttachment) {
        self.attachment = attachment
        session = attachment.session
        attachmentID = attachment.id
        liveManager.levelsOfUndo = 0
    }
    func install(
        editors: [(NativeHistoryAppKitTextView, HistoryField<String>)], localEditors: [NativeHistoryAppKitTextView]
    ) async throws {
        let all = editors.map(\.0) + localEditors
        guard !editors.isEmpty, Set(all.map(ObjectIdentifier.init)).count == all.count,
            all.allSatisfy({ $0.historyFacade == nil })
        else { throw invalidInput() }
        // Acquire fields before replacing any native control routing.
        var values: [String] = []
        for (_, field) in editors { values.append(try await session.nativeCoordinator.register(field)) }
        guard let attachment else { throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable) }
        try attachment.requireCurrent()
        for (index, pair) in editors.enumerated() {
            let (editor, field) = pair
            let control = AppKitHistoryControl(editor: editor, field: field.id, manager: liveManager)
            control.facade = AppKitHistoryUndoManager(
                owner: self, editor: editor, registrationManager: liveManager,
                unknownManager: session.nativeCoordinator.undoManager)
            editor.historyFacade = control.facade
            editor.editingAdmission = self
            controls.append(control)
            render(control: control, value: values[index])
        }
        for editor in localEditors {
            let manager = UndoManager()
            let control = AppKitHistoryControl(editor: editor, field: nil, manager: manager)
            control.facade = AppKitHistoryUndoManager(owner: self, editor: editor, registrationManager: manager)
            editor.historyFacade = control.facade
            localControls.append(control)
        }
        session.nativeCoordinator.register(self)
        try attachment.requireCurrent()
        for control in controls {
            session.nativeCoordinator.restoreTransaction(
                attachment: attachmentID, control: control.id, field: control.field!)
        }
        observeEditors()
        publishAvailability()
    }
    private var hasMarkedText: Bool { controls.contains { $0.editor?.hasMarkedText() == true } }
    private func compositionRefusal() -> HistorySubmissionResult {
        .unexecuted(HistoryFailure(.busy, stage: .admission, disposition: .usable))
    }
    public func commit() async -> HistorySubmissionResult {
        guard available, !hasMarkedText else { return compositionRefusal() }
        guard !disconnected else { return retired() }
        let result = await session.settleEditing()
        lastResult = result
        return result
    }
    public func undoDocument() async -> HistorySubmissionResult {
        guard available, !hasMarkedText else { return compositionRefusal() }
        guard !disconnected else { return retired() }
        let result = await session.undo()
        lastResult = result
        return result
    }
    public func redoDocument() async -> HistorySubmissionResult {
        guard available, !hasMarkedText else { return compositionRefusal() }
        guard !disconnected else { return retired() }
        let result = await session.redo()
        lastResult = result
        return result
    }
    public func retryDraft() async -> HistorySubmissionResult {
        guard !disconnected else { return retired() }
        let result = await session.nativeCoordinator.retryDraft()
        lastResult = result
        return result
    }
    public func discardDraft() async -> HistorySubmissionResult {
        guard !disconnected else { return retired() }
        return await session.nativeCoordinator.discardDraft()
    }
    private func retired() -> HistorySubmissionResult {
        .unexecuted(HistoryFailure(.identityConflict, stage: .admission, disposition: .usable))
    }
    public func waitForOperations() async { await session.waitForNativeOperations() }
    public func disconnect() { attachment?.disconnect() }
    public func close() async {
        guard !disconnected else { return }
        await session.close()
    }
    @discardableResult public func requestCommit() -> Bool { settleEditing() }
    @discardableResult public func settleEditing() -> Bool {
        guard !disconnected else { return false }
        return session.nativeCoordinator.requestSettlement(attachment: attachmentID)
    }
    func admitChange(in editor: NativeHistoryAppKitTextView) -> Bool {
        guard !rendering, let control = controls.first(where: { $0.editor === editor }), let field = control.field
        else { return !rendering }
        return session.nativeCoordinator.beginChange(
            attachment: attachmentID, control: control.id, field: field, composing: editor.hasMarkedText())
    }
    func capture(control: UUID) -> (value: String, composing: Bool)? {
        guard let editor = controls.first(where: { $0.id == control })?.editor else { return nil }
        return (editor.string, editor.hasMarkedText())
    }
    func render(field: String, value: String) {
        for control in controls where control.field == field { render(control: control, value: value) }
    }
    private func render(control: AppKitHistoryControl, value: String) {
        guard let editor = control.editor, editor.string != value else { return }
        rendering = true
        defer { rendering = false }
        let selections = editor.selectedRanges.map(\.rangeValue)
        editor.string = value
        editor.selectedRanges = selections.map { selection in
            let start = min(selection.location, value.utf16.count)
            return NSValue(range: NSRange(location: start, length: min(selection.length, value.utf16.count - start)))
        }
    }
    func liveManager(control: UUID) -> UndoManager? {
        controls.contains(where: { $0.id == control }) ? liveManager : nil
    }
    func retire(transaction: UUID) {
        controls.compactMap(\.editor).forEach { $0.breakUndoCoalescing() }
        liveManager.removeAllActions()
        publishAvailability()
    }
    func detach() {
        guard !disconnected else { return }
        disconnected = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for control in controls + localControls {
            if let editor = control.editor, editor.historyFacade === control.facade {
                editor.breakUndoCoalescing()
                editor.historyFacade = nil
                editor.editingAdmission = nil
            }
            control.facade?.owner = nil
        }
        controls.removeAll()
        localControls.removeAll()
    }
    func publishAvailability() {
        guard !disconnected else { return }
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: documentFacade)
        for control in controls + localControls {
            guard let facade = control.facade else { continue }
            let signature = "\(facade.canUndo)|\(facade.canRedo)|\(facade.undoActionName)|\(facade.redoActionName)"
            if signature != control.lastAvailability {
                control.lastAvailability = signature
                NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: facade)
                NSApp.mainMenu?.update()
            }
        }
    }
    private func selectedManager(for editor: NativeHistoryAppKitTextView?) -> UndoManager? {
        let selected =
            editor ?? (controls + localControls).compactMap(\.editor).first { $0.window?.firstResponder === $0 }
        if let local = localControls.first(where: { $0.editor === selected }) { return local.manager }
        guard available, !disconnected else { return nil }
        let control = controls.first { $0.editor === selected }
        guard !controls.contains(where: { $0.editor?.hasMarkedText() == true }) else { return nil }
        if let live = session.nativeCoordinator.liveManager(attachment: attachmentID, control: control?.id) {
            guard let control,
                session.nativeCoordinator.permitsEditing(
                    attachment: attachmentID, control: control.id, composing: false)
            else { return nil }
            return live
        }
        return session.nativeCoordinator.undoManager
    }
    fileprivate func recognizes(_ target: Any) -> Bool {
        controls.contains {
            guard let editor = $0.editor else { return false }
            return target as AnyObject === editor || target as AnyObject === editor.textStorage
        }
    }
    fileprivate func canUndo(editor: NativeHistoryAppKitTextView?, undo: Bool) -> Bool {
        guard let manager = selectedManager(for: editor) else { return false }
        return undo ? manager.canUndo : manager.canRedo
    }
    fileprivate func name(editor: NativeHistoryAppKitTextView?, undo: Bool) -> String {
        guard let manager = selectedManager(for: editor) else { return "" }
        return undo ? manager.undoActionName : manager.redoActionName
    }
    fileprivate func invoke(editor: NativeHistoryAppKitTextView?, undo: Bool) {
        guard let manager = selectedManager(for: editor), undo ? manager.canUndo : manager.canRedo else { return }
        if undo { manager.undo() } else { manager.redo() }
        if let control = controls.first(where: { $0.editor === editor }), let field = control.field,
            let value = capture(control: control.id) {
            session.nativeCoordinator.changed(
                attachment: attachmentID, control: control.id, field: field, value: value.value,
                composing: value.composing)
        }
        publishAvailability()
    }
    private func invalidInput() -> HistoryFailure {
        HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
    }
}

@MainActor final class AppKitHistoryControl {
    let id = UUID()
    weak var editor: NativeHistoryAppKitTextView?
    let field: String?
    let manager: UndoManager
    var facade: AppKitHistoryUndoManager?
    var lastAvailability = ""
    init(editor: NativeHistoryAppKitTextView, field: String?, manager: UndoManager) {
        self.editor = editor
        self.field = field
        self.manager = manager
    }
}

@MainActor final class AppKitHistoryUndoManager: UndoManager {
    weak var owner: NativeHistoryAppKitBinding?
    weak var editor: NativeHistoryAppKitTextView?
    let registrationManager: UndoManager
    let unknownManager: UndoManager?
    init(
        owner: NativeHistoryAppKitBinding, editor: NativeHistoryAppKitTextView? = nil,
        registrationManager: UndoManager, unknownManager: UndoManager? = nil
    ) {
        self.owner = owner
        self.editor = editor
        self.registrationManager = registrationManager
        self.unknownManager = unknownManager
        super.init()
    }
    private func destination(_ target: Any) -> UndoManager {
        if unknownManager == nil || owner?.recognizes(target) == true { return registrationManager }
        return unknownManager!
    }
    override var groupsByEvent: Bool {
        get { registrationManager.groupsByEvent }
        set { registrationManager.groupsByEvent = newValue }
    }
    override var groupingLevel: Int { registrationManager.groupingLevel }
    override var isUndoing: Bool { registrationManager.isUndoing }
    override var isRedoing: Bool { registrationManager.isRedoing }
    override var isUndoRegistrationEnabled: Bool { registrationManager.isUndoRegistrationEnabled }
    override var levelsOfUndo: Int {
        get { registrationManager.levelsOfUndo }
        set { registrationManager.levelsOfUndo = newValue }
    }
    override var runLoopModes: [RunLoop.Mode] {
        get { registrationManager.runLoopModes }
        set { registrationManager.runLoopModes = newValue }
    }
    override func beginUndoGrouping() { registrationManager.beginUndoGrouping() }
    override func endUndoGrouping() { registrationManager.endUndoGrouping() }
    override func disableUndoRegistration() { registrationManager.disableUndoRegistration() }
    override func enableUndoRegistration() { registrationManager.enableUndoRegistration() }
    override func setActionName(_ actionName: String) { registrationManager.setActionName(actionName) }
    override func removeAllActions() { registrationManager.removeAllActions() }
    override func removeAllActions(withTarget target: Any) { registrationManager.removeAllActions(withTarget: target) }
    override func prepare(withInvocationTarget target: Any) -> Any {
        destination(target).prepare(withInvocationTarget: target)
    }
    override var canUndo: Bool { owner?.canUndo(editor: editor, undo: true) ?? false }
    override var canRedo: Bool { owner?.canUndo(editor: editor, undo: false) ?? false }
    override var undoActionName: String { owner?.name(editor: editor, undo: true) ?? "" }
    override var redoActionName: String { owner?.name(editor: editor, undo: false) ?? "" }
    override func undo() { owner?.invoke(editor: editor, undo: true) }
    override func redo() { owner?.invoke(editor: editor, undo: false) }
    override func __registerUndoWithTarget(_ target: Any, handler: @escaping @MainActor @Sendable (Any) -> Void) {
        destination(target).__registerUndoWithTarget(target, handler: handler)
    }
    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        destination(target).registerUndo(withTarget: target, selector: selector, object: anObject)
    }
}
#endif
