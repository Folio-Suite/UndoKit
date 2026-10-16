// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import UIKit
import DurableNotesCore
import UndoKit

@MainActor final class NotesUIKitController: UIViewController {
    let owner: NotesSceneOwner
    private var attachment: HistoryAttachment?
    let titleEditor = NativeHistoryTextView()
    let bodyEditor = NativeHistoryTextView()
    let scratch = UITextView()
    let status = UILabel()
    private(set) var undoButton: UIButton!
    private(set) var redoButton: UIButton!
    private(set) var binding: NativeHistoryUIKitBinding?
    private var buttons: [UIButton] = []
    private var feedback: String?
    private var uiOperation: Task<Void, Never>?
    var lastResult: HistorySubmissionResult? { binding?.lastResult }

    init(owner: NotesSceneOwner) { self.owner = owner; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(owner:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        title = "Durable Note \(owner.id.prefix(6))"
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)
        ])
        addLabel("Persisted title and body; one scope per scene", to: stack)
        addEditor(titleEditor, label: "Title", height: 65, to: stack)
        addEditor(bodyEditor, label: "Body", height: 150, to: stack)
        for (label, selector) in [("Undo", #selector(undoTapped)), ("Redo", #selector(redoTapped)),
            ("Commit / retry typing", #selector(commitTapped)), ("Discard uncommitted draft", #selector(discardTapped)),
            ("Apply grouped example", #selector(exampleTapped)), ("Reject next edit", #selector(rejectTapped)),
            ("Delay next edit", #selector(delayTapped))] {
            let button = addButton(label, selector: selector, to: stack); buttons.append(button)
            if label == "Undo" { undoButton = button }
            if label == "Redo" { redoButton = button }
        }
        #if DEBUG
        buttons.append(addButton("Accept then fail finalization", selector: #selector(failureTapped), to: stack))
        #endif
        addButton("Release delayed outcome", selector: #selector(releaseTapped), to: stack)
        addButton("Close / reopen", selector: #selector(reopenTapped), to: stack)
        addButton("New independent scene (iPad)", selector: #selector(sceneTapped), to: stack)
        addButton("Toggle storage availability", selector: #selector(storageTapped), to: stack)
        addButton("Finish sample after graceful close", selector: #selector(finishTapped), to: stack)
        status.numberOfLines = 0; status.accessibilityIdentifier = "Status"; stack.addArrangedSubview(status)
        addLabel("Local scratch: independent, unsubmitted, not persisted", to: stack)
        addEditor(scratch, label: "Local scratch", height: 100, to: stack)
        addLabel("Finish marked text before committing. Pending semantic work blocks this scene; local scratch and other scenes remain independent.", to: stack)
        lifecycleChanged()
    }
    private func addLabel(_ text: String, to stack: UIStackView) {
        let label = UILabel(); label.text = text; label.numberOfLines = 0; stack.addArrangedSubview(label)
    }
    private func addEditor(_ editor: UITextView, label: String, height: CGFloat, to stack: UIStackView) {
        editor.font = .preferredFont(forTextStyle: .body); editor.adjustsFontForContentSizeCategory = true
        editor.backgroundColor = .secondarySystemBackground; editor.layer.cornerRadius = 8
        editor.accessibilityLabel = label; editor.accessibilityIdentifier = label
        stack.addArrangedSubview(editor)
        editor.heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    @discardableResult private func addButton(_ title: String, selector: Selector, to stack: UIStackView) -> UIButton {
        let button = UIButton(type: .system); button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = title; button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: selector, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        stack.addArrangedSubview(button); return button
    }
    func attach() async throws {
        guard let session = owner.session else { return }
        if binding?.status.phase == .closed { binding?.disconnect(); binding = nil }
        guard binding == nil else { lifecycleChanged(); return }
        guard let lease = owner.lease else { return }
        attachment = try session.attach(owner: self, statusDidChange: { controller, _ in controller.renderStatus() })
        binding = try await attachment!.bindUIKit(editors: [
            (titleEditor, try lease.field(.title, in: session)),
            (bodyEditor, try lease.field(.body, in: session))], localEditors: [scratch])
        lifecycleChanged()
    }
    private func render(_ note: Note) {
        for (editor, value) in [(titleEditor, note.title), (bodyEditor, note.body)] {
            let selection = editor.selectedRange
            if editor.text != value { editor.text = value }
            editor.selectedRange = NSRange(location: min(selection.location, value.utf16.count),
                length: min(selection.length, max(0, value.utf16.count - min(selection.location, value.utf16.count))))
        }
    }
    func refresh() async { renderStatus() }
    func lifecycleChanged() {
        binding?.isAvailable = owner.mayEdit
        // The framework's delegate barrier preserves selection/focus while native work drains.
        renderStatus()
    }
    private func renderStatus() {
        let state = owner.session?.status
        let available = owner.mayEdit && state?.phase == .ready && state?.requiresDraftDecision == false
        buttons.forEach {
            let recovery = $0.accessibilityIdentifier == "Commit / retry typing" || $0.accessibilityIdentifier == "Discard uncommitted draft"
            $0.isEnabled = recovery ? owner.mayEdit && state?.phase != .busy && state?.phase != .closing : available
        }
        undoButton?.isEnabled = binding?.undoManager.canUndo == true
        redoButton?.isEnabled = binding?.undoManager.canRedo == true
        status.text = "Scene \(owner.state.rawValue); history \(String(describing: state?.phase)); live editing \(binding?.hasLiveTransaction == true).\n\(state?.requiresDraftDecision == true ? "Draft retained: retry or discard. " : "")\(feedback ?? "")"
    }
    func showMessage(_ message: String) { feedback = message; renderStatus() }
    func waitForOperations() async { await uiOperation?.value; await binding?.waitForOperations() }
    func apply(title: String, body: String) {
        guard let session = owner.session, let lease = owner.lease else { return }
        uiOperation = Task { @MainActor in
            _ = await lease.edit(title: title, body: body, in: session)
        }
    }
    func discardDraft() async { _ = await binding?.discardDraft() }
    func commitDraft() { _ = binding?.requestCommit() }
    @objc private func undoTapped() { binding?.undoManager.undo(); renderStatus() }
    @objc private func redoTapped() { binding?.undoManager.redo(); renderStatus() }
    @objc private func commitTapped() {
        if let session = owner.session, session.snapshot.isSuspended {
            Task { _ = await session.reconcile() }
        } else if owner.session?.status.requiresDraftDecision == true {
            Task { _ = await binding?.retryDraft() }
        } else { commitDraft() }
    }
    @objc private func discardTapped() { Task { await discardDraft() } }
    @objc private func exampleTapped() { apply(title: "Shopping", body: "Tea and bread") }
    @objc private func rejectTapped() { Task { await owner.lease?.rejectNextDelivery(); showMessage("Next semantic delivery will be rejected") } }
    @objc private func delayTapped() { Task { await owner.lease?.delayNextDelivery(); showMessage("Next delivery waits for Release delayed outcome") } }
    @objc private func releaseTapped() { Task { await owner.lease?.resumeDelivery() } }
    #if DEBUG
    @objc private func failureTapped() {
        guard let session = owner.session, let lease = owner.lease else { return }
        Task { _ = await lease.demonstrateFinalizationFailure(title: titleEditor.text ?? "", body: bodyEditor.text ?? "", in: session) }
    }
    #endif
    @objc private func reopenTapped() { Task { if await owner.close(reason: "explicit reopen") { await owner.openIfAvailable() } } }
    @objc private func sceneTapped() { owner.app?.requestNewScene() }
    @objc private func finishTapped() { owner.app?.finishSample() }
    private var pretendStorageAvailable = true
    @objc private func storageTapped() { pretendStorageAvailable.toggle(); Task { await owner.setStorageAvailable(pretendStorageAvailable) } }
}
