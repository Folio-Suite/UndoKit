// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
import UIKit

/// UIKit mechanics for a presentation attached to the shared session.
@MainActor public final class NativeHistoryUIKitBinding: NSObject, UITextViewDelegate, HistoryNativePlatformAdapter {
    let session: HistorySession
    let attachmentID: UUID
    private weak var attachment: HistoryAttachment?
    var controls: [UIKitHistoryControl] = []
    var localControls: [UIKitHistoryControl] = []
    var observers: [NSObjectProtocol] = []
    var rendering = false
    var disconnected = false
    var pendingSwiftUIEditingEnd: (() -> Void)?
    var available = true
    public var isAvailable: Bool {
        get { available }
        set {
            available = newValue
            publishAvailability()
        }
    }
    lazy var toolbarFacade = UIKitHistoryUndoManager(
        owner: self, registrationManager: session.nativeCoordinator.undoManager)
    public var undoManager: UndoManager { toolbarFacade }
    public var status: HistorySessionStatus { session.status }
    public var hasLiveTransaction: Bool { session.nativeCoordinator.hasLiveTransaction(attachment: attachmentID) }
    public var permitsEditing: Bool { available && !disconnected && !status.isEditingBlocked }
    public private(set) var lastResult: HistorySubmissionResult?
    init(attachment: HistoryAttachment) {
        self.attachment = attachment
        session = attachment.session
        attachmentID = attachment.id
        super.init()
    }
    func install(editors: [(NativeHistoryTextView, HistoryField<String>)], localEditors: [UITextView]) async throws {
        let all: [UITextView] = editors.map(\.0) + localEditors
        guard !editors.isEmpty, Set(all.map(ObjectIdentifier.init)).count == all.count,
            editors.allSatisfy({ $0.0.historyFacade == nil })
        else { throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable) }
        var values: [String] = []
        for (_, field) in editors { values.append(try await session.nativeCoordinator.register(field)) }
        guard let attachment else { throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable) }
        try attachment.requireCurrent()
        for (index, pair) in editors.enumerated() {
            let (editor, field) = pair
            let control = UIKitHistoryControl(editor: editor, field: field.id)
            control.facade = UIKitHistoryUndoManager(
                owner: self, editor: editor, registrationManager: session.nativeCoordinator.undoManager)
            controls.append(control)
            render(control: control, value: values[index])
            editor.historyFacade = control.facade
            editor.delegate = self
        }
        for editor in localEditors {
            localControls.append(UIKitHistoryControl(editor: editor, field: nil))
            editor.delegate = self
        }
        session.nativeCoordinator.register(self)
        try attachment.requireCurrent()
        for control in controls {
            session.nativeCoordinator.restoreTransaction(
                attachment: attachmentID, control: control.id, field: control.field!)
        }
        observeNativeManagers()
        publishAvailability()
    }
    private var hasMarkedText: Bool { controls.contains { $0.editor?.markedTextRange != nil } }
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
    public func close() async {
        guard !disconnected else { return }
        await session.close()
    }
    public func disconnect() { attachment?.disconnect() }
    @discardableResult public func requestCommit() -> Bool {
        guard !disconnected else { return false }
        return session.nativeCoordinator.requestSettlement(attachment: attachmentID)
    }
    func capture(control: UUID) -> (value: String, composing: Bool)? {
        guard let editor = controls.first(where: { $0.id == control })?.editor else { return nil }
        return (editor.text ?? "", editor.markedTextRange != nil)
    }
    func render(field: String, value: String) {
        for control in controls where control.field == field { render(control: control, value: value) }
    }
    private func render(control: UIKitHistoryControl, value: String) {
        guard let editor = control.editor, editor.text != value else { return }
        rendering = true
        defer { rendering = false }
        let selection = editor.selectedRange
        editor.text = value
        let start = min(selection.location, value.utf16.count)
        editor.selectedRange = NSRange(location: start, length: min(selection.length, value.utf16.count - start))
    }
    func liveManager(control: UUID) -> UndoManager? {
        (controls.first { $0.id == control }?.editor as? NativeHistoryTextView)?.originalUndoManager
    }
    func retire(transaction: UUID) {
        // Only the coordinator's matching transaction can retire a known live stack.
        for control in controls { (control.editor as? NativeHistoryTextView)?.originalUndoManager?.removeAllActions() }
        publishAvailability()
    }
    func detach() {
        guard !disconnected else { return }
        disconnected = true
        pendingSwiftUIEditingEnd = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for control in controls {
            if let editor = control.editor as? NativeHistoryTextView, editor.historyFacade === control.facade {
                editor.historyFacade = nil
            }
            if control.editor?.delegate === self { control.editor?.delegate = control.previousDelegate }
            control.facade?.owner = nil
        }
        for control in localControls where control.editor?.delegate === self {
            control.editor?.delegate = control.previousDelegate
        }
        controls.removeAll()
        localControls.removeAll()
    }
    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String)
        -> Bool {
        if localControls.contains(where: { $0.editor === textView }) { return true }
        pendingSwiftUIEditingEnd?()
        pendingSwiftUIEditingEnd = nil
        guard let control = controls.first(where: { $0.editor === textView }), let field = control.field else {
            return false
        }
        return session.nativeCoordinator.beginChange(
            attachment: attachmentID, control: control.id, field: field, composing: textView.markedTextRange != nil)
    }
    public func textViewDidChange(_ textView: UITextView) {
        if !rendering, let control = controls.first(where: { $0.editor === textView }), let field = control.field {
            _ = session.nativeCoordinator.beginChange(
                attachment: attachmentID, control: control.id, field: field, composing: textView.markedTextRange != nil)
            session.nativeCoordinator.changed(
                attachment: attachmentID, control: control.id, field: field,
                value: textView.text ?? "", composing: textView.markedTextRange != nil)
        }
        publishAvailability()
    }
    public func textViewDidBeginEditing(_ textView: UITextView) {
        pendingSwiftUIEditingEnd?()
        pendingSwiftUIEditingEnd = nil
        if let control = controls.first(where: { $0.editor === textView }) {
            session.nativeCoordinator.focusBoundary(attachment: attachmentID, beginningControl: control.id)
        }
        publishAvailability()
    }
    public func textViewDidEndEditing(_ textView: UITextView) {
        guard let editor = textView as? NativeHistoryTextView, editor.isManagedBySwiftUI else {
            finishEditingBoundary(for: textView)
            return
        }
        let generation = editor.swiftUIPresentationGeneration
        pendingSwiftUIEditingEnd = { [weak self, weak editor] in
            guard let self, let editor, generation == editor.swiftUIPresentationGeneration,
                !editor.isTemporarilyDetachedBySwiftUI, editor.window != nil
            else { return }
            self.finishEditingBoundary(for: editor)
        }
        DispatchQueue.main.async { [weak self] in
            self?.pendingSwiftUIEditingEnd?()
            self?.pendingSwiftUIEditingEnd = nil
        }
    }
    private func finishEditingBoundary(for textView: UITextView) {
        if let control = controls.first(where: { $0.editor === textView }) {
            session.nativeCoordinator.focusBoundary(attachment: attachmentID, beginningControl: control.id)
        }
        publishAvailability()
    }
    public func textViewDidChangeSelection(_ textView: UITextView) {
        if let control = controls.first(where: { $0.editor === textView }), let field = control.field,
            hasLiveTransaction {
            session.nativeCoordinator.changed(
                attachment: attachmentID, control: control.id, field: field,
                value: textView.text ?? "", composing: textView.markedTextRange != nil)
        }
        publishAvailability()
    }
}

@MainActor final class UIKitHistoryControl {
    let id = UUID()
    weak var editor: UITextView?
    weak var previousDelegate: (any UITextViewDelegate)?
    let field: String?
    var facade: UIKitHistoryUndoManager?
    var lastAvailability = ""
    init(editor: UITextView, field: String?) {
        self.editor = editor
        self.field = field
        previousDelegate = editor.delegate
    }
}
#endif
