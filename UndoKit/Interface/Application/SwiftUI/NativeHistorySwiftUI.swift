// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// The durable UndoManager facade carried through a SwiftUI subtree.
private struct NativeHistoryUndoManagerKey: EnvironmentKey {
    public static let defaultValue: UndoManager? = nil
}

extension EnvironmentValues {
    public var nativeHistoryUndoManager: UndoManager? {
        get { self[NativeHistoryUndoManagerKey.self] }
        set { self[NativeHistoryUndoManagerKey.self] = newValue }
    }
}

/// Presents the framework's standard UIKit-backed editor in a SwiftUI hierarchy.
/// Keep `textView` in the stable scene/document owner; rebuilding this value view
/// then moves the same UIKit editor and preserves its local Undo registrations.
/// SwiftUI values reference the editor weakly; the mounted native container retains
/// it only while presented. Cached view values cannot extend the editor's lifetime.
@MainActor public struct NativeHistorySwiftUIEditor: View {
    private let reference: NativeHistorySwiftUIEditorReference

    public init(textView: UITextView) {
        reference = NativeHistorySwiftUIEditorReference(textView)
    }

    public var body: some View {
        NativeHistorySwiftUIEditorPresentation(reference: reference)
            .onAppear { reference.appear() }
            .onDisappear { reference.disappear() }
    }
}

/// One value's visibility callbacks identify its own native host, even when
/// SwiftUI makes the replacement before dismantling the prior presentation.
@MainActor private final class NativeHistorySwiftUIEditorReference {
    let presentation: NativeHistorySwiftUIEditorOwnership
    weak var container: NativeHistorySwiftUIEditorContainer?

    init(_ editor: UITextView) {
        presentation = NativeHistorySwiftUIEditorOwnership.forEditor(editor)
    }
    func appear() {
        guard let container, presentation.isCurrent(container) else { return }
        (presentation.editor as? NativeHistoryTextView)?.isTemporarilyDetachedBySwiftUI = false
    }
    func disappear() {
        guard let container, presentation.isCurrent(container) else { return }
        (presentation.editor as? NativeHistoryTextView)?.detachSwiftUIPresentation()
    }
}

/// Neither the weak-key table nor waiting hosts retain the editor or its owner.
@MainActor private final class NativeHistorySwiftUIEditorOwnership {
    private static let presentations = NSMapTable<UITextView, NativeHistorySwiftUIEditorOwnership>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)
    weak var editor: UITextView?
    private let ownership = NativeHistoryPresentationOwnership()

    static func forEditor(_ editor: UITextView) -> NativeHistorySwiftUIEditorOwnership {
        if let existing = presentations.object(forKey: editor) { return existing }
        let presentation = NativeHistorySwiftUIEditorOwnership()
        presentation.editor = editor
        presentations.setObject(presentation, forKey: editor)
        return presentation
    }
    func isCurrent(_ container: NativeHistorySwiftUIEditorContainer) -> Bool { ownership.isCurrent(container) }
    func attach(_ container: NativeHistorySwiftUIEditorContainer) { ownership.attach(container) }
    func detach(_ container: NativeHistorySwiftUIEditorContainer) { ownership.detach(container) }
}

private struct NativeHistorySwiftUIEditorPresentation: UIViewRepresentable {
    let reference: NativeHistorySwiftUIEditorReference

    func makeUIView(context: Context) -> NativeHistorySwiftUIEditorContainer {
        let container = NativeHistorySwiftUIEditorContainer()
        container.present(reference)
        return container
    }
    func updateUIView(_ container: NativeHistorySwiftUIEditorContainer, context: Context) {
        container.present(reference)
    }
    static func dismantleUIView(_ container: NativeHistorySwiftUIEditorContainer, coordinator: ()) {
        container.detach()
    }
}

@MainActor private final class NativeHistorySwiftUIEditorContainer: UIView, NativeHistoryPresentationHost {
    private var reference: NativeHistorySwiftUIEditorReference?
    private weak var mountedEditor: UITextView?
    var canMountPresentedEditor: Bool { reference?.presentation.editor?.superview == nil }
    private var editorConstraints: [NSLayoutConstraint] = []
    private let diagnostic = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        diagnostic.text = "This native editor is already presented elsewhere. Give each scene its own editor instance."
        diagnostic.numberOfLines = 0
        diagnostic.textColor = .systemRed
        diagnostic.accessibilityIdentifier = "NativeHistorySwiftUIEditorAttachmentError"
        diagnostic.translatesAutoresizingMaskIntoConstraints = false
        addSubview(diagnostic)
        NSLayoutConstraint.activate([
            diagnostic.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            diagnostic.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            diagnostic.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func present(_ reference: NativeHistorySwiftUIEditorReference) {
        if self.reference?.presentation !== reference.presentation { detach() }
        self.reference = reference
        reference.container = self
        reference.presentation.attach(self)
    }
    func mountPresentedEditor() {
        guard let editor = reference?.presentation.editor else { showUnavailableEditor(); return }
        mountedEditor = editor
        diagnostic.isHidden = true
        (editor as? NativeHistoryTextView)?.isManagedBySwiftUI = true
        addSubview(editor)
        (editor as? NativeHistoryTextView)?.isTemporarilyDetachedBySwiftUI = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        editorConstraints = [
            editor.leadingAnchor.constraint(equalTo: leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor),
            editor.topAnchor.constraint(equalTo: topAnchor),
            editor.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(editorConstraints)
    }
    func showUnavailableEditor() {
        removeEditor()
        diagnostic.text = "The owning document no longer has this editor."
        diagnostic.isHidden = false
    }
    func detach() {
        let previous = reference
        reference = nil
        previous?.presentation.detach(self)
    }
    func unmountPresentedEditor() { removeEditor() }
    func removeEditor() {
        guard let editor = mountedEditor else { return }
        (editor as? NativeHistoryTextView)?.detachSwiftUIPresentation()
        NSLayoutConstraint.deactivate(editorConstraints)
        editorConstraints = []
        if editor.superview === self { editor.removeFromSuperview() }
        mountedEditor = nil
    }
}

extension View {
    /// Supplies the supported facade through a read-only SwiftUI environment key.
    /// SwiftUI's built-in undoManager environment is read-only on iOS; native
    /// UIResponder routing still comes from NativeHistoryTextView itself.
    @MainActor public func nativeHistory(
        _ binding: NativeHistoryUIKitBinding
    ) -> some View {
        environment(\.nativeHistoryUndoManager, binding.undoManager)
    }
}
#endif
