// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI

/// Presents an existing AppKit-bound text view without replacing its native editor or Undo history.
/// Keep the `textView` and its binding in a stable window owner across SwiftUI value-view updates.
@MainActor public struct NativeHistorySwiftUIEditor: NSViewRepresentable {
    public typealias NSViewType = NSView
    private let presentation: NativeHistorySwiftUIEditorPresentation

    public init(textView: NativeHistoryAppKitTextView) {
        presentation = NativeHistorySwiftUIEditorPresentation.forEditor(textView)
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NativeHistorySwiftUIEditorContainer(frame: .zero)
        container.present(presentation)
        return container
    }

    public func updateNSView(_ view: NSView, context: Context) {
        guard let container = view as? NativeHistorySwiftUIEditorContainer else { return }
        container.present(presentation)
    }

    public static func dismantleNSView(_ view: NSView, coordinator: ()) {
        // SwiftUI value-view teardown releases only the host. The stable owner keeps the editor,
        // binding, live callbacks and session so ordinary reconstruction does not reset typing Undo.
        (view as? NativeHistorySwiftUIEditorContainer)?.detach()
    }
}

/// Weak editor keys preserve identity across independently reconstructed representable values.
/// The table and presentation never own the document, editor, binding, or native host.
@MainActor private final class NativeHistorySwiftUIEditorPresentation {
    private static let presentations = NSMapTable<NativeHistoryAppKitTextView, NativeHistorySwiftUIEditorPresentation>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)
    weak var editor: NativeHistoryAppKitTextView?
    private weak var current: NativeHistorySwiftUIEditorContainer?
    private var waiting: [WeakContainer] = []

    private final class WeakContainer {
        weak var value: NativeHistorySwiftUIEditorContainer?
        init(_ value: NativeHistorySwiftUIEditorContainer) { self.value = value }
    }

    static func forEditor(_ editor: NativeHistoryAppKitTextView) -> NativeHistorySwiftUIEditorPresentation {
        if let existing = presentations.object(forKey: editor) { return existing }
        let presentation = NativeHistorySwiftUIEditorPresentation()
        presentation.editor = editor
        presentations.setObject(presentation, forKey: editor)
        return presentation
    }

    func attach(_ container: NativeHistorySwiftUIEditorContainer) {
        waiting.removeAll { $0.value == nil }
        guard let editor else { container.showUnavailableEditor(); return }
        if current === container { return }
        guard current == nil, editor.superview == nil else {
            if !waiting.contains(where: { $0.value === container }) { waiting.append(WeakContainer(container)) }
            return
        }
        current = container
        container.mount(editor)
    }

    func detach(_ container: NativeHistorySwiftUIEditorContainer) {
        waiting.removeAll { $0.value == nil || $0.value === container }
        guard current === container else { return }
        current = nil
        container.removeEditor()
        // SwiftUI may create/update the replacement before dismantling the old host.
        // Promote only after the owner of the existing presentation releases it.
        if let replacement = waiting.compactMap(\.value).first {
            waiting.removeAll { $0.value === replacement }
            attach(replacement)
        }
    }
}

@MainActor final class NativeHistorySwiftUIEditorContainer: NSView {
    private var presentation: NativeHistorySwiftUIEditorPresentation?
    private weak var mountedEditor: NativeHistoryAppKitTextView?
    private let diagnostic = NSTextField(wrappingLabelWithString: "This editor is already presented by another SwiftUI view.")
    private let scrollView = NSScrollView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        diagnostic.isHidden = false
        diagnostic.textColor = .secondaryLabelColor
        diagnostic.setAccessibilityLabel("Editor is already presented in another window")
        addSubview(diagnostic)
        diagnostic.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            diagnostic.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 8),
            diagnostic.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -8),
            diagnostic.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    fileprivate func present(_ presentation: NativeHistorySwiftUIEditorPresentation) {
        if self.presentation !== presentation {
            detach()
            self.presentation = presentation
        }
        presentation.attach(self)
    }

    fileprivate func mount(_ editor: NativeHistoryAppKitTextView) {
        mountedEditor = editor
        diagnostic.isHidden = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        scrollView.documentView = editor
    }

    fileprivate func showUnavailableEditor() {
        removeEditor()
        diagnostic.stringValue = "The owning document no longer has this editor."
        diagnostic.isHidden = false
    }

    func detach() {
        let previous = presentation
        presentation = nil
        previous?.detach(self)
        removeEditor()
    }

    fileprivate func removeEditor() {
        if scrollView.documentView === mountedEditor { scrollView.documentView = nil }
        mountedEditor = nil
    }
}

private struct NativeHistoryAppKitUndoManagerKey: EnvironmentKey {
    static let defaultValue: UndoManager? = nil
}

extension EnvironmentValues {
    /// The manager for explicit SwiftUI actions; native Edit menu routing remains AppKit's responder chain.
    public var nativeHistoryUndoManager: UndoManager? {
        get { self[NativeHistoryAppKitUndoManagerKey.self] }
        set { self[NativeHistoryAppKitUndoManagerKey.self] = newValue }
    }
}

extension View {
    /// Makes a binding's manager available to SwiftUI controls that invoke document history explicitly.
    @MainActor public func nativeHistory<Lease: NativeHistoryLease>(
        _ binding: NativeHistoryAppKitBinding<Lease>
    ) -> some View {
        environment(\.nativeHistoryUndoManager, binding.undoManager)
    }
}
#endif
