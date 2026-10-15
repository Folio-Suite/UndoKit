// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import AppKit
import DurableNotesCore
import UndoKit

@MainActor final class NotesWindow: NSWindow {
    weak var history: UndoManager?
    override var undoManager: UndoManager? { history }
    @objc func undo(_ sender: Any?) { history?.undo() }
    @objc func redo(_ sender: Any?) { history?.redo() }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return history?.canUndo ?? false }
        if item.action == #selector(redo(_:)) { return history?.canRedo ?? false }
        return super.validateUserInterfaceItem(item)
    }
}

/// Host-owned mapping and presentation only; UndoKit owns editing and recovery.
@MainActor final class NotesWindowController: NSWindowController, NSWindowDelegate {
    static let sessions = NativeHistorySessions<NotesDocumentLease>()
    let session: NativeHistorySession<NotesDocumentLease>
    let lease: NotesDocumentLease
    let directory: URL
    var binding: NativeHistoryAppKitBinding<NotesDocumentLease>!
    let titleEditor = NativeHistoryAppKitTextView()
    let bodyEditor = NativeHistoryAppKitTextView()
    let scratch = NativeHistoryAppKitTextView()
    let status = NSTextField(labelWithString: "")
    private var operationButtons: [NSButton] = []
    private var uiOperation: Task<Void, Never>?
    private var readout: NotesReadout?
    var lastResult: HistoryResult? { binding.lastResult }
    private(set) var refreshCount = 0

    static func open(at directory: URL, name: String) async throws -> NotesWindowController {
        let lease = NotesDocumentLease(directory: directory)
        let mode = try NotesDocumentRegistry(root: directory.deletingLastPathComponent()).openMode(for: directory)
        let session = await sessions.open(documentURL: directory, mode: mode, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        guard session.status.phase == .ready else { throw session.status.issue ?? HistoryFailure(.storage, stage: .admission, disposition: .suspended) }
        let controller = NotesWindowController(session: session, lease: lease, directory: directory, name: name)
        try controller.connect(); await controller.refresh()
        return controller
    }
    private init(session: NativeHistorySession<NotesDocumentLease>, lease: NotesDocumentLease, directory: URL, name: String) {
        self.session = session; self.lease = lease; self.directory = directory
        let window = NotesWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Durable Notes — \(name)"; window.isReleasedWhenClosed = false; window.delegate = self
        buildInterface()
    }
    required init?(coder: NSCoder) { fatalError("Use open(at:name:)") }
    private func buildInterface() {
        guard let view = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
        stack.addArrangedSubview(NSTextField(labelWithString: "Persisted note (native live Undo; Commit typing persists one group)"))
        addEditor(titleEditor, label: "Title", height: 45, to: stack)
        addEditor(bodyEditor, label: "Body", height: 170, to: stack)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 8
        for (title, action) in [("Commit typing", #selector(commitTyping(_:))),
                                 ("Apply grouped example", #selector(applyExample(_:))),
                                 ("Reject next edit", #selector(rejectNext(_:))),
                                 ("Delay next edit", #selector(delayNext(_:)))] {
            let button = NSButton(title: title, target: self, action: action)
            operationButtons.append(button); buttons.addArrangedSubview(button)
        }
        stack.addArrangedSubview(buttons)
        let recovery = NSStackView(); recovery.orientation = .horizontal; recovery.spacing = 8
        #if DEBUG
        let failure = NSButton(title: "Accept then fail finalization", target: self, action: #selector(failFinalization(_:)))
        operationButtons.append(failure); recovery.addArrangedSubview(failure)
        #endif
        recovery.addArrangedSubview(NSButton(title: "Release delayed outcome", target: self, action: #selector(resume(_:))))
        recovery.addArrangedSubview(NSButton(title: "Close / reopen", target: self, action: #selector(reopen(_:))))
        stack.addArrangedSubview(recovery)
        let decisions = NSStackView(); decisions.orientation = .horizontal; decisions.spacing = 8
        decisions.addArrangedSubview(NSButton(title: "Retry draft", target: self, action: #selector(retry(_:))))
        decisions.addArrangedSubview(NSButton(title: "Discard draft", target: self, action: #selector(discard(_:))))
        stack.addArrangedSubview(decisions)
        status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 3
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(NSTextField(labelWithString: "Local scratch (not persisted; Undo never reaches the note)"))
        addEditor(scratch, label: "Local scratch", height: 115, to: stack)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString:
            "Cmd-Z / Shift-Cmd-Z follow focus. Finish marked text before semantic Undo. Reopen restores committed history without replaying effects."))
    }
    private func addEditor(_ editor: NSTextView, label: String, height: CGFloat, to stack: NSStackView) {
        editor.isRichText = false; editor.allowsUndo = true; editor.delegate = nil
        editor.font = .systemFont(ofSize: 14); editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.setAccessibilityLabel(label)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = editor; scroll.translatesAutoresizingMaskIntoConstraints = false
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([scroll.heightAnchor.constraint(equalToConstant: height),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    private func connect() throws {
        binding = try session.connectAppKit(owner: self, editors: [titleEditor, bodyEditor], localEditors: [scratch],
            actionName: "Edit Note", captureDraft: {
                NativeDraftCapture(value: Note(title: $0.titleEditor.string, body: $0.bodyEditor.string),
                    isComposing: $0.titleEditor.hasMarkedText() || $0.bodyEditor.hasMarkedText())
            }, draftDidChange: { owner, note in
                owner.titleEditor.string = note.title; owner.bodyEditor.string = note.body
            }, statusDidChange: { owner, value in
                owner.renderStatus()
                if value.phase == .ready { Task { [weak owner] in await owner?.refresh() } }
            })
        (window as? NotesWindow)?.history = binding.undoManager
        renderStatus()
    }
    @discardableResult func settleEditing() -> Bool { binding.settleEditing() }
    func waitForOperations() async { await uiOperation?.value; await binding.waitForOperations() }
    func read() async throws -> NotesReadout { try await lease.read() }
    func refresh() async {
        readout = try? await lease.read(); refreshCount += 1; renderStatus()
    }
    private func renderStatus() {
        guard let binding else { return }
        let editable = binding.permitsEditing
        // Changing isEditable while composition is active would destroy native input.
        if !titleEditor.hasMarkedText() { titleEditor.isEditable = editable }
        if !bodyEditor.hasMarkedText() { bodyEditor.isEditable = editable }
        operationButtons.forEach { $0.isEnabled = editable }
        let state = binding.status
        let outcome: String
        if !binding.isAvailable { outcome = "Storage unavailable; restore its original location before retrying." }
        else if state.phase == .busy || !editable && state.phase == .ready { outcome = "Pending authoritative outcome." }
        else if state.requiresDraftDecision { outcome = "Retained draft: choose Retry draft or Discard draft." }
        else if let issue = state.issue { outcome = "History requires recovery: \(issue.cause)." }
        else { outcome = "Native Undo/Redo is live. Commit typing persists one transaction." }
        status.stringValue = "\(outcome) Applications: \(readout?.applicationCount ?? 0); receipts: \(readout?.receiptCount ?? 0)."
    }
    func apply(title: String, body: String) {
        uiOperation = Task { [weak self] in
            guard let self else { return }; _ = await binding.applyDraft(Note(title: title, body: body)); await refresh()
        }
    }
    @objc private func applyExample(_ sender: Any?) { apply(title: "Shopping", body: "Tea and bread") }
    @objc private func commitTyping(_ sender: Any?) {
        uiOperation = Task { [weak self] in
            guard let self else { return }; _ = await binding.commit(); await refresh()
        }
    }
    @objc private func rejectNext(_ sender: Any?) {
        uiOperation = Task { [weak self] in await self?.lease.rejectNextDelivery(); self?.status.stringValue = "Next semantic delivery will be rejected." }
    }
    @objc private func delayNext(_ sender: Any?) {
        uiOperation = Task { [weak self] in await self?.lease.delayNextDelivery(); self?.status.stringValue = "Next delivery waits until Release delayed outcome." }
    }
    @objc private func resume(_ sender: Any?) { Task { await lease.resumeDelivery() } }
    @objc private func retry(_ sender: Any?) {
        uiOperation = Task { [weak self] in guard let self else { return }; _ = await binding.retryDraft(); await refresh() }
    }
    @objc private func discard(_ sender: Any?) {
        uiOperation = Task { [weak self] in guard let self else { return }; _ = await binding.discardDraft(); await refresh() }
    }
    #if DEBUG
    @objc private func failFinalization(_ sender: Any?) {
        uiOperation = Task { [weak self] in
            guard let self else { return }
            try? session.updateDraft(Note(title: "Recovery", body: "Durably accepted once"))
            titleEditor.string = "Recovery"; bodyEditor.string = "Durably accepted once"
            _ = await binding.demonstrateFinalizationFailure(); await refresh()
        }
    }
    #endif
    @objc private func reopen(_ sender: Any?) {
        uiOperation = Task { [weak self] in
            do { try await self?.reopenSession() } catch { self?.status.stringValue = "Reopen refused: \(error)" }
        }
    }
    func reopenSession() async throws {
        await binding.close()
        guard session.status.phase == .closed else { throw session.status.issue ?? HistoryFailure(.busy, stage: .admission, disposition: .suspended) }
        // Reacquire while still attached: a disconnected closed owner is deliberately retired.
        await Self.sessions.reopen(session)
        binding.disconnect()
        guard session.status.phase == .ready else { throw session.status.issue ?? HistoryFailure(.storage, stage: .admission, disposition: .suspended) }
        try connect(); await refresh()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard settleEditing() else { return false }; sender.orderOut(nil); return false
    }
}
