// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import UIKit
import DurableNotesCore
import UndoKit

@MainActor final class NotesTextView: UITextView {
    let local: Bool
    private let fallbackLocalHistory = UndoManager()
    var localHistory: UndoManager { super.undoManager ?? fallbackLocalHistory }
    weak var router: NativeHistoryRouter?
    var editingAllowed: (() -> Bool)?
    init(local: Bool = false) { self.local = local; super.init(frame: .zero, textContainer: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(local:)") }
    override var undoManager: UndoManager? { local ? localHistory : router?.undoManager }
    private var permitsInput: Bool { local || (editingAllowed?() == true && router?.isEditingBlocked == false) }
    override func insertText(_ text: String) { if permitsInput { super.insertText(text) } }
    override func deleteBackward() { if permitsInput { super.deleteBackward() } }
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if permitsInput { super.setMarkedText(markedText, selectedRange: selectedRange) }
    }
    override func replace(_ range: UITextRange, withText text: String) {
        if permitsInput { super.replace(range, withText: text) }
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(notesUndo(_:))),
         UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(notesRedo(_:)))]
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(notesUndo(_:)) { return local || undoManager?.canUndo == true }
        if action == #selector(notesRedo(_:)) { return local || undoManager?.canRedo == true }
        if !permitsInput && [#selector(cut(_:)), #selector(paste(_:)), #selector(delete(_:))].contains(action) { return false }
        return super.canPerformAction(action, withSender: sender)
    }
    @objc func notesUndo(_ sender: Any?) { undoManager?.undo() }
    @objc func notesRedo(_ sender: Any?) { undoManager?.redo() }
}

@MainActor final class NotesUIKitController: UIViewController, UITextViewDelegate {
    let owner: NotesSceneOwner
    let titleEditor = NotesTextView()
    let bodyEditor = NotesTextView()
    let scratch = NotesTextView(local: true)
    let status = UILabel()
    private(set) var undoButton: UIButton!
    private(set) var redoButton: UIButton!
    var router = NativeHistoryRouter()
    private var tail: Task<Void, Never>?
    private var provisional = false
    private var draftNeedsDecision = false
    private var updating = false
    private var readout: NotesReadout?
    private var buttons: [UIButton] = []
    private(set) var lastResult: HistoryResult?
    private var feedback: String?
    private var draftURL: URL { owner.directory.appendingPathComponent("Draft.json") }
    private struct Draft: Codable { let title: String; let body: String }

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
    private func addEditor(_ editor: NotesTextView, label: String, height: CGFloat, to stack: UIStackView) {
        editor.font = .preferredFont(forTextStyle: .body); editor.adjustsFontForContentSizeCategory = true
        editor.backgroundColor = .secondarySystemBackground; editor.layer.cornerRadius = 8
        editor.accessibilityLabel = label; editor.accessibilityIdentifier = label
        editor.delegate = self; stack.addArrangedSubview(editor)
        editor.heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    @discardableResult private func addButton(_ title: String, selector: Selector, to stack: UIStackView) -> UIButton {
        let button = UIButton(type: .system); button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = title; button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: selector, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        stack.addArrangedSubview(button); return button
    }
    func attach() throws {
        guard let session = owner.session else { return }
        router = NativeHistoryRouter(); titleEditor.router = router; bodyEditor.router = router
        titleEditor.editingAllowed = { [weak owner] in owner?.mayEdit == true }
        bodyEditor.editingAllowed = { [weak owner] in owner?.mayEdit == true }
        lastResult = nil; feedback = nil
        router.settleEditing = { [weak self] in self?.settleEditing() ?? false }
        router.undoRequested = { [weak self] in self?.inverse(undo: true) }
        router.redoRequested = { [weak self] in self?.inverse(undo: false) }
        router.barrierChanged = { [weak self] _ in self?.lifecycleChanged() }
        router.routingStateChanged = { [weak self] _ in self?.renderStatus() }
        session.engine.snapshotDidChange = { [weak self] snapshot in self?.router.update(snapshot: snapshot, undoName: "Edit Note", redoName: "Edit Note") }
        try router.attach(snapshot: session.engine.snapshot, undoName: "Edit Note", redoName: "Edit Note")
    }
    func textViewDidChange(_ textView: UITextView) {
        guard !updating, textView !== scratch else { return }
        provisional = true; router.noteProvisionalEdit()
    }
    func textViewDidEndEditing(_ textView: UITextView) { if textView !== scratch { _ = settleEditing() } }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        textView === scratch || (owner.mayEdit && !router.isEditingBlocked)
    }
    @discardableResult func settleEditing(forLifecycle: Bool = false) -> Bool {
        guard let session = owner.session, !draftNeedsDecision,
              titleEditor.markedTextRange == nil, bodyEditor.markedTextRange == nil else { return false }
        guard owner.mayEdit || forLifecycle else { return false }
        guard provisional else { return true }
        provisional = false
        let title = titleEditor.text ?? "", body = bodyEditor.text ?? ""
        router.didQueueProvisionalEdit()
        enqueue { [weak self] in
            guard let self else { return }
            let result = await session.edit(title: title, body: body)
            self.router.didFinishQueuedEdit(); self.lastResult = result
            if case .accepted = result { }
            else {
                let authoritative = await session.read().note
                if authoritative != Note(title: title, body: body) {
                    self.provisional = true; self.draftNeedsDecision = true; self.router.noteProvisionalEdit()
                }
            }
            await self.refresh()
        }
        return true
    }
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let prior = tail; tail = Task { @MainActor in await prior?.value; await operation() }
    }
    func waitForOperations() async { await tail?.value }
    private func inverse(undo: Bool) {
        guard let id = router.pendingInvocationID, let session = owner.session else { return }
        enqueue { [weak self] in
            guard let self else { return }
            guard !self.draftNeedsDecision else {
                self.router.finishInvocation(id, snapshot: session.engine.snapshot)
                self.renderStatus(); return
            }
            self.lastResult = undo ? await session.undo() : await session.redo()
            await self.refresh()
            self.router.finishInvocation(id, snapshot: session.engine.snapshot, undoName: "Edit Note", redoName: "Edit Note")
        }
    }
    func apply(title: String, body: String, injectFailure: Bool = false) {
        guard owner.mayEdit, settleEditing(), let session = owner.session, let id = router.beginExternalOperation() else { return }
        enqueue { [weak self] in
            guard let self else { return }
            guard !self.draftNeedsDecision else {
                self.router.finishInvocation(id, snapshot: session.engine.snapshot)
                self.renderStatus(); return
            }
            #if DEBUG
            self.lastResult = injectFailure ? await session.demonstrateFinalizationFailure(title: title, body: body)
                : await session.edit(title: title, body: body)
            #else
            self.lastResult = await session.edit(title: title, body: body)
            #endif
            await self.refresh()
            self.router.finishInvocation(id, snapshot: session.engine.snapshot, undoName: "Edit Note", redoName: "Edit Note")
        }
    }
    func refresh() async {
        guard let session = owner.session else { return }
        readout = await session.read(); updating = true
        router.undoManager.disableUndoRegistration()
        if !provisional { titleEditor.text = readout?.note.title; bodyEditor.text = readout?.note.body }
        router.undoManager.enableUndoRegistration(); updating = false
        router.update(snapshot: session.engine.snapshot, undoName: "Edit Note", redoName: "Edit Note")
        lifecycleChanged()
    }
    func lifecycleChanged() {
        let editable = owner.mayEdit && !router.isEditingBlocked
        // UIKit resigns text focus when isEditable becomes false. During native
        // pending work preserve focus/selection and refuse changes in the delegate.
        titleEditor.isEditable = owner.mayEdit; bodyEditor.isEditable = owner.mayEdit
        buttons.forEach { $0.isEnabled = editable }
        renderStatus()
    }
    private func renderStatus() {
        let draft = draftNeedsDecision ? " Uncommitted draft retained; choose retry or discard." : ""
        let outcome: String
        if case .rejected = lastResult { outcome = " Rejected: no semantic effect." }
        else if case .failure(let failure) = lastResult { outcome = " \(failure.cause): \(failure.disposition)." }
        else { outcome = "" }
        status.text = "Scene \(owner.state.rawValue); routing \(router.routingState). Applications: \(readout?.applicationCount ?? 0); receipts: \(readout?.receiptCount ?? 0).\(outcome)\(draft)\(feedback.map { " \($0)" } ?? "")"
    }
    func showMessage(_ message: String) { feedback = message; renderStatus() }
    func persistDraftIfNeeded() throws {
        if provisional || titleEditor.markedTextRange != nil || bodyEditor.markedTextRange != nil {
            try JSONEncoder().encode(Draft(title: titleEditor.text ?? "", body: bodyEditor.text ?? ""))
                .write(to: draftURL, options: [.atomic, .completeFileProtection])
        } else if FileManager.default.fileExists(atPath: draftURL.path) {
            try FileManager.default.removeItem(at: draftURL)
        }
    }
    func restoreDraft() throws {
        guard FileManager.default.fileExists(atPath: draftURL.path) else { return }
        let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: draftURL))
        if readout?.note == Note(title: draft.title, body: draft.body) {
            try FileManager.default.removeItem(at: draftURL); return
        }
        updating = true; titleEditor.text = draft.title; bodyEditor.text = draft.body; updating = false
        provisional = true; draftNeedsDecision = true; router.noteProvisionalEdit(); renderStatus()
    }
    func discardDraft() async {
        provisional = false; draftNeedsDecision = false; router.didSettleProvisionalEdit()
        try? FileManager.default.removeItem(at: draftURL)
        await refresh()
    }
    func commitDraft() { draftNeedsDecision = false; _ = settleEditing() }
    @objc private func undoTapped() { (scratch.isFirstResponder ? scratch.localHistory : router.undoManager).undo() }
    @objc private func redoTapped() { (scratch.isFirstResponder ? scratch.localHistory : router.undoManager).redo() }
    @objc private func commitTapped() { commitDraft() }
    @objc private func discardTapped() { Task { await discardDraft() } }
    @objc private func exampleTapped() { apply(title: "Shopping", body: "Tea and bread") }
    @objc private func rejectTapped() { Task { await owner.session?.rejectNextDelivery(); showMessage("Next semantic delivery will be rejected") } }
    @objc private func delayTapped() { Task { await owner.session?.delayNextDelivery(); showMessage("Next delivery waits for Release delayed outcome") } }
    @objc private func releaseTapped() { Task { await owner.session?.resumeDelivery() } }
    #if DEBUG
    @objc private func failureTapped() { apply(title: "Recovered", body: "Accepted once", injectFailure: true) }
    #endif
    @objc private func reopenTapped() { Task { if await owner.close(reason: "explicit reopen") { await owner.openIfAvailable() } } }
    @objc private func sceneTapped() { owner.app?.requestNewScene() }
    @objc private func finishTapped() { owner.app?.finishSample() }
    private var pretendStorageAvailable = true
    @objc private func storageTapped() { pretendStorageAvailable.toggle(); Task { await owner.setStorageAvailable(pretendStorageAvailable) } }
}
