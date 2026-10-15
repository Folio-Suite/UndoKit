// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

#if canImport(AppKit)
import AppKit

/// Standard AppKit text editing with UndoKit routing for durable document history.
/// AppKit retains ownership of input, selection, marked text and live Undo callbacks.
@MainActor public final class NativeHistoryAppKitTextView: NSTextView {
    weak var historyFacade: UndoManager?
    weak var editingAdmission: (any AppKitEditingAdmission)?
    var originalUndoManager: UndoManager? { super.undoManager }
    public override var undoManager: UndoManager? { historyFacade ?? super.undoManager }
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

extension NativeHistorySession {
    /// Connect standard AppKit editors to one document session. Local editors keep an
    /// isolated native history and never fall through to the document's durable history.
    /// Retain the returned binding for the lifetime of the presentation.
    public func connectAppKit<Owner: AnyObject>(owner: Owner,
        editors: [NativeHistoryAppKitTextView], localEditors: [NativeHistoryAppKitTextView] = [],
        actionName: String = "",
        captureDraft: @escaping @MainActor (Owner) -> NativeDraftCapture<Lease.Draft>?,
        draftDidChange: @escaping @MainActor (Owner, Lease.Draft) -> Void,
        statusDidChange: (@MainActor (Owner, NativeHistoryStatus) -> Void)? = nil
    ) throws -> NativeHistoryAppKitBinding<Lease> {
        try NativeHistoryAppKitBinding(session: self, owner: owner, editors: editors,
            localEditors: localEditors, actionName: actionName, captureDraft: captureDraft,
            draftDidChange: draftDidChange, statusDidChange: statusDidChange)
    }
}
#endif
