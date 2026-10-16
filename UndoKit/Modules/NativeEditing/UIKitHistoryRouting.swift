// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
import UIKit

extension NativeHistoryUIKitBinding {
    func selectedManager(for editor: NativeHistoryTextView?) -> UndoManager? {
        if editor == nil, let local = localControls.first(where: { $0.editor?.isFirstResponder == true })?.editor {
            return local.undoManager
        }
        guard available, !disconnected, !controls.contains(where: { $0.editor?.markedTextRange != nil }) else {
            return nil
        }
        let selected =
            editor ?? controls.compactMap { $0.editor as? NativeHistoryTextView }.first(where: \.isFirstResponder)
        let control = controls.first { $0.editor === selected }
        if let live = session.nativeCoordinator.liveManager(attachment: attachmentID, control: control?.id) {
            guard let control,
                session.nativeCoordinator.permitsEditing(
                    attachment: attachmentID, control: control.id, composing: false)
            else { return nil }
            return live
        }
        return session.nativeCoordinator.undoManager
    }
    func canUndo(for editor: NativeHistoryTextView?, undo: Bool) -> Bool {
        guard let manager = selectedManager(for: editor) else { return false }
        return undo ? manager.canUndo : manager.canRedo
    }
    func name(for editor: NativeHistoryTextView?, undo: Bool) -> String {
        guard let manager = selectedManager(for: editor) else { return "" }
        return undo ? manager.undoActionName : manager.redoActionName
    }
    func invoke(for editor: NativeHistoryTextView?, undo: Bool) {
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
    func publishAvailability() {
        guard !disconnected else { return }
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: toolbarFacade)
        for control in controls {
            guard let editor = control.editor as? NativeHistoryTextView, let facade = control.facade else { continue }
            let signature = "\(facade.canUndo)|\(facade.canRedo)|\(facade.undoActionName)|\(facade.redoActionName)"
            guard signature != control.lastAvailability else { continue }
            control.lastAvailability = signature
            NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: facade)
            if editor.isFirstResponder, editor.markedTextRange == nil { editor.reloadInputViews() }
        }
    }
    func observeNativeManagers() {
        for name in [
            Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let identity = note.object.map { ObjectIdentifier($0 as AnyObject) }
                    let name = note.name
                    MainActor.assumeIsolated {
                        guard let self, !self.disconnected else { return }
                        for control in self.controls {
                            guard let editor = control.editor as? NativeHistoryTextView,
                                let original = editor.originalUndoManager, ObjectIdentifier(original) == identity,
                                let facade = control.facade
                            else { continue }
                            NotificationCenter.default.post(name: name, object: facade)
                        }
                        self.publishAvailability()
                    }
                })
        }
    }
}

@MainActor final class UIKitHistoryUndoManager: UndoManager {
    weak var owner: NativeHistoryUIKitBinding?
    weak var editor: NativeHistoryTextView?
    let registrationManager: UndoManager
    init(owner: NativeHistoryUIKitBinding, editor: NativeHistoryTextView? = nil, registrationManager: UndoManager) {
        self.owner = owner
        self.editor = editor
        self.registrationManager = registrationManager
        super.init()
    }
    override var canUndo: Bool { owner?.canUndo(for: editor, undo: true) ?? false }
    override var canRedo: Bool { owner?.canUndo(for: editor, undo: false) ?? false }
    override var undoActionName: String { owner?.name(for: editor, undo: true) ?? "" }
    override var redoActionName: String { owner?.name(for: editor, undo: false) ?? "" }
    override func undo() { owner?.invoke(for: editor, undo: true) }
    override func redo() { owner?.invoke(for: editor, undo: false) }
    override func __registerUndoWithTarget(_ target: Any, handler: @escaping @MainActor @Sendable (Any) -> Void) {
        registrationManager.__registerUndoWithTarget(target, handler: handler)
    }
    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        registrationManager.registerUndo(withTarget: target, selector: selector, object: anObject)
    }
}
#endif
