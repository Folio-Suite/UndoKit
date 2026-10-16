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

extension HistoryAttachment {
    /// Binds standard UIKit controls to optional field drafts on this session.
    public func bindUIKit(
        editors: [(NativeHistoryTextView, HistoryField<String>)],
        localEditors: [UITextView] = []
    ) async throws -> NativeHistoryUIKitBinding {
        guard !disconnected, platform == nil else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        try requireCurrent()
        let binding = NativeHistoryUIKitBinding(attachment: self)
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
