// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

#if canImport(AppKit)
import AppKit

/// Standard AppKit text editing with UndoKit routing for durable document history.
/// AppKit retains ownership of input, selection, marked text and live Undo callbacks.
@MainActor public final class NativeHistoryAppKitTextView: NSTextView {
    var isTemporarilyDetachedBySwiftUI = false
    weak var historyFacade: UndoManager?
    weak var editingAdmission: (any AppKitEditingAdmission)?
    var originalUndoManager: UndoManager? { super.undoManager }
    public override var undoManager: UndoManager? { historyFacade ?? super.undoManager }
    @objc public func undo(_ sender: Any?) { undoManager?.undo() }
    @objc public func redo(_ sender: Any?) { undoManager?.redo() }
    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return undoManager?.canUndo ?? false }
        if item.action == #selector(redo(_:)) { return undoManager?.canRedo ?? false }
        return super.validateUserInterfaceItem(item)
    }
    public override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard editingAdmission?.admitChange(in: self) ?? true else { return false }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }
    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard editingAdmission?.admitChange(in: self) ?? true else { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
}

@MainActor protocol AppKitEditingAdmission: AnyObject {
    func admitChange(in editor: NativeHistoryAppKitTextView) -> Bool
}

extension HistoryAttachment {
    /// Binds native text controls to field declarations on this shared session.
    public func bindAppKit(
        editors: [(NativeHistoryAppKitTextView, HistoryField<String>)],
        localEditors: [NativeHistoryAppKitTextView] = []
    ) async throws -> NativeHistoryAppKitBinding {
        guard !disconnected, platform == nil else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        try requireCurrent()
        let binding = NativeHistoryAppKitBinding(attachment: self)
        platform = binding
        do {
            try await binding.install(editors: editors, localEditors: localEditors)
            try requireCurrent()
            return binding
        } catch {
            binding.detach()
            if platform === binding { platform = nil }
            throw error
        }
    }
}
#endif
