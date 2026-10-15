// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
import UIKit

/// Standard UITextView editing with a supplied native history facade.
/// UIKit owns input, selection, composition, paste, and live undo registrations.
@MainActor public final class NativeHistoryTextView: UITextView {
    weak var historyFacade: UndoManager?
    var isManagedBySwiftUI = false
    var isTemporarilyDetachedBySwiftUI = false
    var swiftUIPresentationGeneration: UInt = 0
    func detachSwiftUIPresentation() {
        isTemporarilyDetachedBySwiftUI = true
        swiftUIPresentationGeneration &+= 1
    }
    var originalUndoManager: UndoManager? { super.undoManager }
    public override var undoManager: UndoManager? { historyFacade ?? super.undoManager }
}

extension NativeHistorySession {
    /// Connect standard editors to one document. Local controls never fall through to
    /// document history, including when their local Undo stack is empty.
    /// Keep the returned binding until presentation disconnect; it retains owners weakly.
    public func connectUIKit<Owner: AnyObject>(owner: Owner,
        editors: [NativeHistoryTextView], localEditors: [UITextView] = [], actionName: String = "",
        captureDraft: @escaping @MainActor (Owner) -> NativeDraftCapture<Lease.Draft>?,
        draftDidChange: @escaping @MainActor (Owner, Lease.Draft) -> Void,
        statusDidChange: (@MainActor (Owner, NativeHistoryStatus) -> Void)? = nil
    ) throws -> NativeHistoryUIKitBinding<Lease> {
        try NativeHistoryUIKitBinding(session: self, owner: owner, editors: editors, localEditors: localEditors,
            actionName: actionName, captureDraft: captureDraft, draftDidChange: draftDidChange, statusDidChange: statusDidChange)
    }
}
#endif
