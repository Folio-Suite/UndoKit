// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import AppKit
import DurableNotesCore
import UndoKit

@MainActor final class NotesWindow: NSWindow {
    var router: NativeHistoryRouter?
    override var undoManager: UndoManager? { router?.undoManager }
    @objc func undo(_ sender: Any?) { router?.undoManager.undo() }
    @objc func redo(_ sender: Any?) { router?.undoManager.redo() }
}

/// Local scratch consumes Undo even when empty; it cannot reach document history.
@MainActor final class ScratchTextView: NSTextView {
    let localHistory = UndoManager()
    override var undoManager: UndoManager? { localHistory }
    @objc func undo(_ sender: Any?) { localHistory.undo() }
    @objc func redo(_ sender: Any?) { localHistory.redo() }
}

@MainActor final class NotesWindowController: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    var session: NotesSession
    var router = NativeHistoryRouter()
    let titleEditor = NSTextView()
    let bodyEditor = NSTextView()
    let scratch = ScratchTextView()
    let status = NSTextField(labelWithString: "")
    private var displayed = Note()
    private var updating = false
    private var provisional = false
    private var tail: Task<Void, Never>?
    private var operationButtons: [NSButton] = []
    private var hostApplications = 0
    private var hostReceipts = 0
    private(set) var lastResult: HistoryResult?
    private(set) var refreshCount = 0

    static func open(at directory: URL, name: String) async throws -> NotesWindowController {
        let session = try await NotesSession.open(at: directory)
        let controller = NotesWindowController(session: session, name: name)
        try controller.bindRouter(); await controller.refresh()
        return controller
    }
    private init(session: NotesSession, name: String) {
        self.session = session
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
        stack.addArrangedSubview(NSTextField(labelWithString: "Persisted note (typing follows native Undo Groups)"))
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
        status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 3
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(NSTextField(labelWithString: "Local scratch (not persisted; Undo never reaches the note)"))
        addEditor(scratch, label: "Local scratch", height: 115, to: stack)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString:
            "Cmd-Z / Shift-Cmd-Z follow focus. Finish marked text before semantic Undo. Reopen restores committed history without replaying effects."))
    }
    private func addEditor(_ editor: NSTextView, label: String, height: CGFloat, to stack: NSStackView) {
        editor.isRichText = false; editor.allowsUndo = true; editor.delegate = self
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
    private func bindRouter() throws {
        (window as? NotesWindow)?.router = router
        router.settleEditing = { [weak self] in self?.settleEditing() ?? false }
        // Event-loop groups can close once per keystroke while NSTextView still
        // coalesces a typing run. Keep it provisional until a semantic boundary.
        router.undoRequested = { [weak self] in self?.routeInverse(undo: true) }
        router.redoRequested = { [weak self] in self?.routeInverse(undo: false) }
        router.barrierChanged = { [weak self] blocked in
            self?.titleEditor.isEditable = !blocked; self?.bodyEditor.isEditable = !blocked
            self?.operationButtons.forEach { $0.isEnabled = !blocked }
        }
        router.routingStateChanged = { [weak self] _ in self?.renderStatus() }
        session.engine.snapshotDidChange = { [weak self] snapshot in self?.updateRouter(snapshot) }
        try router.attach(snapshot: session.engine.snapshot)
        updateRouter(session.engine.snapshot)
    }
    func undoManager(for view: NSTextView) -> UndoManager? {
        view === scratch ? scratch.localHistory : router.undoManager
    }
    func textDidChange(_ notification: Notification) {
        guard !updating, let editor = notification.object as? NSTextView, editor !== scratch else { return }
        provisional = true; router.noteProvisionalEdit()
    }
    func textDidEndEditing(_ notification: Notification) { _ = settleEditing() }
    func textViewDidChangeTypingAttributes(_ notification: Notification) {
        router.noteTransientRegistration()
    }

    @discardableResult func settleEditing() -> Bool {
        guard !titleEditor.hasMarkedText(), !bodyEditor.hasMarkedText() else {
            status.stringValue = "Finish marked-text composition before Undo or committing this group."
            return false
        }
        titleEditor.breakUndoCoalescing(); bodyEditor.breakUndoCoalescing()
        guard provisional else { return true }
        provisional = false
        let title = titleEditor.string, body = bodyEditor.string
        if title == displayed.title && body == displayed.body {
            router.didSettleProvisionalEdit(); return true
        }
        router.didQueueProvisionalEdit()
        enqueue { [weak self] in
            guard let self else { return }
            let result = await self.session.edit(title: title, body: body)
            self.lastResult = result; self.router.didFinishQueuedEdit()
            await self.refresh(result: result)
        }
        return true
    }
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let prior = tail
        tail = Task { @MainActor in await prior?.value; await operation() }
    }
    func waitForOperations() async { await tail?.value }
    private func routeInverse(undo: Bool) {
        guard let invocation = router.pendingInvocationID else { return }
        enqueue { [weak self] in
            guard let self else { return }
            let result = undo ? await self.session.undo() : await self.session.redo()
            self.lastResult = result; await self.refresh(result: result)
            self.router.finishInvocation(invocation, snapshot: self.session.engine.snapshot,
                undoName: "Edit Note", redoName: "Edit Note")
        }
    }
    private func updateRouter(_ snapshot: HistorySnapshot) {
        let presentation = try? session.engine.nativeActionNames { payload in
            guard payload.family == "durable-notes.label" else { return nil }
            return String(data: payload.data, encoding: .utf8)
        }
        router.update(snapshot: snapshot, undoName: presentation?.names.undo ?? "", redoName: presentation?.names.redo ?? "")
    }
    func refresh(result: HistoryResult? = nil) async {
        let readout = await session.read(); displayed = readout.note; updating = true
        hostApplications = readout.applicationCount; hostReceipts = readout.receiptCount
        if let result { lastResult = result }
        router.undoManager.disableUndoRegistration()
        if !provisional { titleEditor.string = displayed.title; bodyEditor.string = displayed.body }
        router.undoManager.enableUndoRegistration(); updating = false; refreshCount += 1
        updateRouter(session.engine.snapshot)
        renderStatus()
    }
    private func renderStatus() {
        let outcome: String
        switch router.routingState {
        case .pending: outcome = "Pending: waiting for an authoritative outcome."
        case .suspended: outcome = "History suspended. Close / reopen to reconcile the receipt."
        case .registrationMismatch: outcome = "Native registration requires host attention."
        case .reattachmentRequired: outcome = "History identity requires reattachment."
        case .ready:
            if case .rejected = lastResult { outcome = "Rejected: no domain effect." }
            else { outcome = "Ready. Commit typing or change focus to persist the current typing group." }
        }
        status.stringValue = "\(outcome) Applications: \(hostApplications); receipts: \(hostReceipts)."
    }
    func apply(title: String, body: String) {
        guard settleEditing(), let invocation = router.beginExternalOperation() else { return }
        enqueue { [weak self] in
            guard let self else { return }
            let result = await self.session.edit(title: title, body: body)
            self.lastResult = result; await self.refresh(result: result)
            self.router.finishInvocation(invocation, snapshot: self.session.engine.snapshot,
                undoName: "Edit Note", redoName: "Edit Note")
        }
    }
    @objc private func applyExample(_ sender: Any?) { apply(title: "Shopping", body: "Tea and bread") }
    @objc private func commitTyping(_ sender: Any?) { _ = settleEditing() }
    @objc private func rejectNext(_ sender: Any?) {
        enqueue { [weak self] in
            await self?.session.rejectNextDelivery()
            self?.status.stringValue = "Next semantic delivery will be rejected."
        }
    }
    @objc private func delayNext(_ sender: Any?) {
        enqueue { [weak self] in
            await self?.session.delayNextDelivery()
            self?.status.stringValue = "Next delivery waits until Release delayed outcome."
        }
    }
    @objc private func resume(_ sender: Any?) { Task { await session.resumeDelivery() } }
    #if DEBUG
    @objc private func failFinalization(_ sender: Any?) {
        guard settleEditing(), let invocation = router.beginExternalOperation() else { return }
        enqueue { [weak self] in
            guard let self else { return }
            let result = await self.session.demonstrateFinalizationFailure(title: "Recovery", body: "Durably accepted once")
            self.lastResult = result; await self.refresh(result: result)
            self.router.finishInvocation(invocation, snapshot: self.session.engine.snapshot)
        }
    }
    #endif
    @objc private func reopen(_ sender: Any?) {
        guard settleEditing() else { return }
        enqueue { [weak self] in
            do { try await self?.reopenSession() }
            catch { self?.status.stringValue = "Reopen refused: \(error)" }
        }
    }
    func reopenSession() async throws {
        let directory = session.directory; session.engine.snapshotDidChange = nil
        try await session.close()
        session = try await NotesSession.open(at: directory)
        router = NativeHistoryRouter(); lastResult = nil; try bindRouter(); provisional = false
        await refresh()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the owner alive until graceful app termination, even if hidden.
        guard settleEditing() else { return false }
        sender.orderOut(nil); return false
    }
}
