// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// The durable UndoManager facade carried through a SwiftUI subtree.
private struct NativeHistoryUndoManagerKey: EnvironmentKey {
    public static let defaultValue: UndoManager? = nil
}

public extension EnvironmentValues {
    var nativeHistoryUndoManager: UndoManager? {
        get { self[NativeHistoryUndoManagerKey.self] }
        set { self[NativeHistoryUndoManagerKey.self] = newValue }
    }
}

/// Presents the framework's standard UIKit-backed editor in a SwiftUI hierarchy.
/// Keep `textView` in the stable scene/document owner; rebuilding this value view
/// then moves the same UIKit editor and preserves its local Undo registrations.
/// SwiftUI values reference the editor weakly; the mounted native container retains
/// it only while presented. Cached view values cannot extend the editor's lifetime.
public struct NativeHistorySwiftUIEditor: View {
    private let editor: NativeHistorySwiftUIEditorReference

    public init(textView: UITextView) {
        editor = NativeHistorySwiftUIEditorReference(textView)
    }

    public var body: some View {
        NativeHistorySwiftUIEditorPresentation(editor: editor)
            .onAppear {
                (editor.value as? NativeHistoryTextView)?.isTemporarilyDetachedBySwiftUI = false
            }
            .onDisappear {
                (editor.value as? NativeHistoryTextView)?.detachSwiftUIPresentation()
            }
    }
}

private final class NativeHistorySwiftUIEditorReference {
    weak var value: UITextView?
    init(_ value: UITextView) { self.value = value }
}

private struct NativeHistorySwiftUIEditorPresentation: UIViewRepresentable {
    let editor: NativeHistorySwiftUIEditorReference

    func makeUIView(context: Context) -> NativeHistorySwiftUIEditorContainer {
        let container = NativeHistorySwiftUIEditorContainer()
        attachEditor(to: container)
        return container
    }

    func updateUIView(_ container: NativeHistorySwiftUIEditorContainer, context: Context) {
        attachEditor(to: container)
    }

    static func dismantleUIView(_ container: NativeHistorySwiftUIEditorContainer, coordinator: ()) {
        guard let editor = container.editor, editor.superview === container else { return }
        (editor as? NativeHistoryTextView)?.detachSwiftUIPresentation()
        editor.removeFromSuperview()
    }

    private func attachEditor(to container: NativeHistorySwiftUIEditorContainer) {
        guard let textView = editor.value else { return }
        (textView as? NativeHistoryTextView)?.isManagedBySwiftUI = true
        if textView.superview === container { return }
        guard textView.superview == nil else {
            let diagnostic = UILabel()
            diagnostic.text = "This native editor is already presented elsewhere. Give each scene its own editor instance."
            diagnostic.numberOfLines = 0
            diagnostic.textColor = .systemRed
            diagnostic.accessibilityIdentifier = "NativeHistorySwiftUIEditorAttachmentError"
            diagnostic.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(diagnostic)
            NSLayoutConstraint.activate([
                diagnostic.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                diagnostic.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                diagnostic.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
            return
        }
        container.editor = textView
        container.addSubview(textView)
        (textView as? NativeHistoryTextView)?.isTemporarilyDetachedBySwiftUI = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

private final class NativeHistorySwiftUIEditorContainer: UIView {
    weak var editor: UITextView?
}

public extension View {
    /// Supplies the supported facade through a read-only SwiftUI environment key.
    /// SwiftUI's built-in undoManager environment is read-only on iOS; native
    /// UIResponder routing still comes from NativeHistoryTextView itself.
    @MainActor func nativeHistory<Lease: NativeHistoryLease>(
        _ binding: NativeHistoryUIKitBinding<Lease>
    ) -> some View {
        environment(\.nativeHistoryUndoManager, binding.undoManager)
    }
}
#endif
