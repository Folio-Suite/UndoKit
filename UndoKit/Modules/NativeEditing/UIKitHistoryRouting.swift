// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
import UIKit

extension NativeHistoryUIKitBinding: UIKitHistoryUndoOwner {
    func selectedManager(for editor: NativeHistoryTextView?) -> UndoManager? {
        if editor == nil, let local = localControls.first(where: { $0.editor?.isFirstResponder == true })?.editor {
            return local.undoManager
        }
        guard permitsEditing, !hasMarkedText else { return nil }
        let selected = editor ?? controls.compactMap { $0.editor as? NativeHistoryTextView }.first(where: \.isFirstResponder)
        if liveTransaction { return selected?.originalUndoManager }
        return session.undoManager
    }
    func canUndo(for editor: NativeHistoryTextView?) -> Bool { selectedManager(for: editor)?.canUndo ?? false }
    func canRedo(for editor: NativeHistoryTextView?) -> Bool { selectedManager(for: editor)?.canRedo ?? false }
    func name(for editor: NativeHistoryTextView?, undo: Bool) -> String {
        guard let manager = selectedManager(for: editor) else { return "" }
        if manager === session.undoManager { return actionName }
        return undo ? manager.undoActionName : manager.redoActionName
    }
    func invoke(for editor: NativeHistoryTextView?, undo: Bool) {
        guard let manager = selectedManager(for: editor), undo ? manager.canUndo : manager.canRedo else { return }
        if manager === session.undoManager {
            _ = start { session in
                let result = undo ? await session.undo() : await session.redo()
                return result
            }
        } else {
            undo ? manager.undo() : manager.redo()
            captureLive(); publishAvailability()
        }
    }
    @discardableResult public func requestCommit() -> Bool {
        start { await $0.editing.commitKnownLiveDraft() } != nil
    }
    func resumeDeferredBoundary() {
        guard deferredBoundary, !hasMarkedText, permitsEditing else { return }
        deferredBoundary = false
        _ = requestCommit()
    }
    func perform(_ action: @escaping @MainActor (NativeHistorySession<Lease>) async -> HistoryResult) async -> HistoryResult {
        guard let task = start(action) else {
            return .failure(HistoryFailure(.busy, stage: .admission, disposition: .usable))
        }
        return await task.value
    }
    func start(_ action: @escaping @MainActor (NativeHistorySession<Lease>) async -> HistoryResult) -> Task<HistoryResult, Never>? {
        guard !pending, !disconnected, isAvailable, !hasMarkedText else { return nil }
        captureLive(); pending = true; publishAvailability()
        let session = session
        let task = Task { @MainActor [weak self, session] in
            let result = await action(session)
            guard let self, !self.disconnected else { return result }
            self.lastResult = result; self.pending = false; self.publishAvailability()
            return result
        }
        operation = task
        return task
    }
    func retireAcceptedLiveHistory() {
        guard !disconnected else { return }
        for control in controls {
            guard let editor = control.editor as? NativeHistoryTextView,
                  participants.contains(ObjectIdentifier(editor)) else { continue }
            editor.originalUndoManager?.removeAllActions()
        }
        liveTransaction = false; deferredBoundary = false; participants = []; publishAvailability()
    }
    func publishAvailability() {
        guard !disconnected else { return }
        presentStatus?(session.status)
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: toolbarFacade)
        for control in controls {
            guard let editor = control.editor as? NativeHistoryTextView, let facade = control.facade else { continue }
            let signature = "\(facade.canUndo)|\(facade.canRedo)|\(facade.undoActionName)|\(facade.redoActionName)"
            guard signature != control.lastAvailability else { continue }
            control.lastAvailability = signature
            NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: facade)
            // UIKit's standard input assistant must reread eligibility after asynchronous
            // durable completion. This refresh does not resign focus or replace input.
            if editor.isFirstResponder, editor.markedTextRange == nil { editor.reloadInputViews() }
        }
    }
    func observeNativeManagers() {
        let names: [Notification.Name] = [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                let identity = notification.object.map { ObjectIdentifier($0 as AnyObject) }
                let name = notification.name
                MainActor.assumeIsolated {
                    guard let self, !self.disconnected else { return }
                    for control in self.controls {
                        guard let editor = control.editor as? NativeHistoryTextView,
                              let original = editor.originalUndoManager, ObjectIdentifier(original) == identity,
                              let facade = control.facade else { continue }
                        NotificationCenter.default.post(name: name, object: facade)
                    }
                    self.publishAvailability()
                }
            })
        }
    }

}

@MainActor protocol UIKitHistoryUndoOwner: AnyObject {
    func canUndo(for editor: NativeHistoryTextView?) -> Bool
    func canRedo(for editor: NativeHistoryTextView?) -> Bool
    func name(for editor: NativeHistoryTextView?, undo: Bool) -> String
    func invoke(for editor: NativeHistoryTextView?, undo: Bool)
}

@MainActor final class UIKitHistoryUndoManager: UndoManager {
    weak var owner: (any UIKitHistoryUndoOwner)?
    weak var editor: NativeHistoryTextView?
    let registrationManager: UndoManager
    init(owner: any UIKitHistoryUndoOwner, editor: NativeHistoryTextView? = nil, registrationManager: UndoManager) {
        self.owner = owner; self.editor = editor; self.registrationManager = registrationManager; super.init()
    }
    override var canUndo: Bool { owner?.canUndo(for: editor) ?? false }
    override var canRedo: Bool { owner?.canRedo(for: editor) ?? false }
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
