// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import AppKit
import NativeProofCore

@MainActor
private final class ProofDocument: NSDocument {
    let scopeName: String
    let fixtureURL: URL
    let bridge: NativeBridge
    var mode: ProofMode = .immediate
    var controllers: [ProofWindowController] = []
    private var stagedText: String?
    private var stageTimer: Timer?
    private var events: [String] = []
    private(set) var acceptedChangeBalance = 0

    init(scope: String, directory: URL) {
        scopeName = scope
        fixtureURL = directory.appendingPathComponent("document-\(scope).json")
        if let data = try? Data(contentsOf: fixtureURL),
           let saved = try? JSONDecoder().decode(ProofHistory.self, from: data),
           saved.scope == scope {
            bridge = NativeBridge(history: saved)
        } else {
            bridge = NativeBridge(history: ProofHistory(scope: scope))
        }
        super.init()
        hasUndoManager = true
        bridge.onChange = { [weak self] outcome, origin in self?.bridgeChanged(outcome: outcome, origin: origin) }
        log("Rebuilt scope \(scope), generation \(bridge.history.generation.uuidString.prefix(8)); no domain replay")
    }

    override class var autosavesInPlace: Bool { false }
    override func makeWindowControllers() {}

    override func data(ofType typeName: String) throws -> Data {
        try JSONEncoder().encode(bridge.history)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        // The proof loads its fixture before NSDocument initialization.
    }

    func attach(_ controller: ProofWindowController) {
        controllers.append(controller)
        addWindowController(controller)
        controller.refresh()
    }

    func detach(_ controller: ProofWindowController) {
        controllers.removeAll { $0 === controller }
        removeWindowController(controller)
    }

    func stage(_ text: String) {
        guard !bridge.availability.pending, !bridge.availability.suspended, !bridge.availability.interference else {
            refreshAll()
            log("Edit blocked by pending, suspended or interference state")
            return
        }
        stagedText = text
        stageTimer?.invalidate()
        stageTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleTyping() }
        }
        log("Native text change staged; waiting for typing boundary")
    }

    func settleTyping() {
        stageTimer?.invalidate()
        stageTimer = nil
        guard let stagedText else { return }
        if controllers.contains(where: { $0.editor.hasMarkedText() }) {
            stageTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.settleTyping() }
            }
            return
        }
        controllers.forEach { $0.editor.breakUndoCoalescing() }
        self.stagedText = nil
        if bridge.acceptEdit(stagedText, name: "Typing") {
            updateChangeCount(.changeDone)
            acceptedChangeBalance += 1
            log("Accepted typing group; NSDocument changeDone; native editor coalescing broken")
        }
        persist()
        refreshAll()
    }

    func invoke(undo: Bool, origin: String) {
        guard !controllers.contains(where: { $0.editor.hasMarkedText() }) else {
            log("\(undo ? "Undo" : "Redo") blocked while marked text is composing; commit composition, then retry")
            return
        }
        settleTyping()
        guard bridge.begin(undo: undo, origin: origin) else {
            log("\(undo ? "Undo" : "Redo") ignored: unavailable or already pending")
            return
        }
        let selectedMode = mode
        log("\(undo ? "Undo" : "Redo") began from \(origin); mode \(selectedMode.rawValue)")
        let interval = selectedMode == .delayed ? 10.0 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            _ = self.bridge.finish(mode: selectedMode)
        }
    }

    func noteUnknownRegistration() {
        undoManager?.registerUndo(withTarget: self) { _ in }
        bridge.detectUnknownRegistration()
        log("Unknown native registration detected; semantic routing paused")
    }

    func reconcileRegistration() {
        // The deliberately injected registration is inert. No user work is discarded.
        bridge.reconcileRegistration()
        log("Injected registration classified as inert and reconciled")
    }

    func resolveUnresolved() {
        bridge.reconcileUnresolved()
        log("SIMULATED host authority: unresolved outcome had no effect")
    }

    func reset() {
        stageTimer?.invalidate()
        stagedText = nil
        try? FileManager.default.removeItem(at: fixtureURL)
        log("Scratch fixture removed. Relaunch to establish a new generation")
        refreshAll()
    }

    func log(_ entry: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        events.append("\(stamp)  [\(scopeName)] \(entry)")
        if events.count > 80 { events.removeFirst(events.count - 80) }
        controllers.forEach { $0.refreshLog(events.joined(separator: "\n")) }
    }

    private func bridgeChanged(outcome: ProofOutcome?, origin: String?) {
        switch outcome {
        case .acceptedUndo:
            updateChangeCount(.changeUndone)
            acceptedChangeBalance -= 1
            log("Accepted Undo; NSDocument changeUndone; origin \(origin ?? "unknown")")
            persist()
        case .acceptedRedo:
            updateChangeCount(.changeRedone)
            acceptedChangeBalance += 1
            log("Accepted Redo; NSDocument changeRedone; origin \(origin ?? "unknown")")
            persist()
        case .rejected:
            log("Authoritative rejection, no content or change count update")
            persist()
        case .unresolved:
            log("Unresolved outcome; scope unavailable until reconciliation")
            persist()
        case nil:
            persist()
        }
        refreshAll()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(bridge.history)
            try data.write(to: fixtureURL, options: .atomic)
        } catch {
            log("FIXTURE WRITE FAILED: \(error.localizedDescription)")
        }
    }

    func refreshAll() { controllers.forEach { $0.refresh() } }
    var logText: String { events.joined(separator: "\n") }
}

@MainActor
private final class DocumentTextView: NSTextView {
    weak var proofDocument: ProofDocument?
    var originID = ""
    let typingManager = UndoManager()

    override var undoManager: UndoManager? { typingManager }

    @objc func undo(_ sender: Any?) {
        proofDocument?.invoke(undo: true, origin: originID)
    }

    @objc func redo(_ sender: Any?) {
        proofDocument?.invoke(undo: false, origin: originID)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) {
            let a = proofDocument?.bridge.availability
            menuItem.title = a?.undoName.map { "Undo \($0)" } ?? "Undo"
            return a?.undoID != nil && proofDocument?.controllers.contains(where: { $0.editor.hasMarkedText() }) == false
        }
        if menuItem.action == #selector(redo(_:)) {
            let a = proofDocument?.bridge.availability
            menuItem.title = a?.redoName.map { "Redo \($0)" } ?? "Redo"
            return a?.redoID != nil && proofDocument?.controllers.contains(where: { $0.editor.hasMarkedText() }) == false
        }
        return super.validateMenuItem(menuItem)
    }
}

@MainActor
private final class LocalTextView: NSTextView {
    let localManager = UndoManager()
    override var undoManager: UndoManager? { localManager }

    @objc func undo(_ sender: Any?) {
        if localManager.canUndo { localManager.undo() }
        else { NotificationCenter.default.post(name: .localUndoEmpty, object: self) }
    }

    @objc func redo(_ sender: Any?) {
        if localManager.canRedo { localManager.redo() }
        else { NotificationCenter.default.post(name: .localUndoEmpty, object: self) }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) {
            menuItem.title = localManager.undoActionName.isEmpty ? "Undo Local Text" : "Undo \(localManager.undoActionName)"
            return true // Empty local history consumes the command instead of falling through.
        }
        if menuItem.action == #selector(redo(_:)) {
            menuItem.title = "Redo Local Text"
            return true
        }
        return super.validateMenuItem(menuItem)
    }
}

private extension Notification.Name {
    static let localUndoEmpty = Notification.Name("NativeProofLocalUndoEmpty")
}

@MainActor
private final class ProofWindowController: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    let proofDocument: ProofDocument
    let viewID: String
    let editor: DocumentTextView
    private let local: LocalTextView
    private let status: NSTextField
    private let logView: NSTextView
    private let modePopup: NSPopUpButton
    private var refreshing = false
    private var localObserver: NSObjectProtocol?
    private var nativeObservers: [NSObjectProtocol] = []

    init(document: ProofDocument, viewID: String) {
        proofDocument = document
        self.viewID = viewID
        editor = DocumentTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        local = LocalTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 72))
        status = NSTextField(labelWithString: "")
        logView = NSTextView(frame: .zero)
        modePopup = NSPopUpButton(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 850, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Native Undo Proof — Document \(document.scopeName) — \(viewID)"
        window.identifier = NSUserInterfaceItemIdentifier("NativeProof-\(viewID)")
        window.delegate = self
        buildUI(in: window)
        editor.proofDocument = document
        editor.originID = viewID
        editor.delegate = self
        localObserver = NotificationCenter.default.addObserver(forName: .localUndoEmpty, object: local, queue: .main) { [weak document] _ in
            MainActor.assumeIsolated { document?.log("Empty local Undo consumed; document history untouched") }
        }
        for (name, label) in [
            (Notification.Name("NSUndoManagerDidCloseUndoGroupNotification"), "closed native typing group"),
            (Notification.Name("NSUndoManagerDidUndoChangeNotification"), "did native Undo"),
            (Notification.Name("NSUndoManagerDidRedoChangeNotification"), "did native Redo")
        ] {
            nativeObservers.append(NotificationCenter.default.addObserver(forName: name, object: editor.typingManager, queue: .main) { [weak document] _ in
                MainActor.assumeIsolated { document?.log("Native editor \(viewID) \(label)") }
            })
        }
        document.attach(self)
        window.title = "Native Undo Proof — Document \(document.scopeName) — \(viewID)"
    }

    required init?(coder: NSCoder) { fatalError("Disposable proof uses programmatic windows") }

    private func buildUI(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        let intro = NSTextField(labelWithString: "Type in document text, pause 0.55 s, then use Edit > Undo/Redo or ⌘Z / ⇧⌘Z. Local draft has independent Undo.")
        intro.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(intro)
        stack.addArrangedSubview(NSTextField(labelWithString: "Document text (\(viewID))"))
        configure(editor, id: "document-editor-\(viewID)")
        let editorScroll = NSScrollView()
        editorScroll.hasVerticalScroller = true
        editorScroll.documentView = editor
        editorScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        stack.addArrangedSubview(editorScroll)
        stack.addArrangedSubview(NSTextField(labelWithString: "Local draft (select here, then ⌘Z; empty history stays local)"))
        configure(local, id: "local-editor-\(viewID)")
        let localScroll = NSScrollView()
        localScroll.hasVerticalScroller = true
        localScroll.documentView = local
        localScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        stack.addArrangedSubview(localScroll)
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 7
        modePopup.addItems(withTitles: ProofMode.allCases.map(\.rawValue))
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        modePopup.setAccessibilityIdentifier("outcome-mode-\(viewID)")
        controls.addArrangedSubview(modePopup)
        for (title, selector, id) in [
            ("Show A", #selector(showA(_:)), "show-a"),
            ("Show B", #selector(showB(_:)), "show-b"),
            ("Clone A", #selector(cloneA(_:)), "clone-a"),
            ("Detach clone", #selector(detachClone(_:)), "detach-clone"),
            ("Reopen clone", #selector(cloneA(_:)), "reopen-clone"),
            ("Inject unknown", #selector(injectUnknown(_:)), "inject-unknown"),
            ("Reconcile", #selector(reconcile(_:)), "reconcile"),
            ("Resolve", #selector(resolve(_:)), "resolve")
        ] {
            let button = NSButton(title: title, target: self, action: selector)
            button.setAccessibilityIdentifier(id)
            controls.addArrangedSubview(button)
        }
        stack.addArrangedSubview(controls)
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 5
        status.setAccessibilityIdentifier("status-\(viewID)")
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(NSTextField(labelWithString: "Event log"))
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.setAccessibilityIdentifier("event-log-\(viewID)")
        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.documentView = logView
        logScroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        stack.addArrangedSubview(logScroll)
    }

    private func configure(_ view: NSTextView, id: String) {
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.setAccessibilityIdentifier(id)
    }

    func textDidChange(_ notification: Notification) {
        guard !refreshing, notification.object as AnyObject? === editor else { return }
        proofDocument.stage(editor.string)
    }

    func refresh() {
        let a = proofDocument.bridge.availability
        let text = proofDocument.bridge.history.content
        if editor.string != text && proofDocument.bridge.pending == nil {
            refreshing = true
            editor.string = text
            refreshing = false
        }
        editor.isEditable = !a.pending && !a.suspended && !a.interference
        if modePopup.titleOfSelectedItem != proofDocument.mode.rawValue {
            modePopup.selectItem(withTitle: proofDocument.mode.rawValue)
        }
        status.stringValue = "scope=\(a.scope) generation=\(a.generation.uuidString.prefix(8)) version=\(a.version)\nundo=\(a.undoName ?? "—") redo=\(a.redoName ?? "—") pending=\(a.pending) suspended=\(a.suspended) mismatch=\(a.interference)\nNSDocument edited=\(proofDocument.isDocumentEdited) proof change balance=\(proofDocument.acceptedChangeBalance) content=\(text.debugDescription)"
        refreshLog(proofDocument.logText)
    }

    func refreshLog(_ value: String) { logView.string = value }

    func windowWillClose(_ notification: Notification) {
        proofDocument.detach(self)
        if let localObserver { NotificationCenter.default.removeObserver(localObserver) }
        nativeObservers.forEach(NotificationCenter.default.removeObserver)
        proofDocument.log("View \(viewID) detached")
    }

    @objc private func modeChanged(_ sender: Any?) {
        proofDocument.mode = ProofMode.allCases[modePopup.indexOfSelectedItem]
        proofDocument.log("Outcome mode \(proofDocument.mode.rawValue)")
        proofDocument.refreshAll()
    }
    @objc private func cloneA(_ sender: Any?) { (NSApp.delegate as? ProofAppDelegate)?.showCloneA() }
    @objc private func showA(_ sender: Any?) { (NSApp.delegate as? ProofAppDelegate)?.showDocument("A") }
    @objc private func showB(_ sender: Any?) { (NSApp.delegate as? ProofAppDelegate)?.showDocument("B") }
    @objc private func detachClone(_ sender: Any?) { (NSApp.delegate as? ProofAppDelegate)?.closeCloneA() }
    @objc private func injectUnknown(_ sender: Any?) { proofDocument.noteUnknownRegistration() }
    @objc private func reconcile(_ sender: Any?) { proofDocument.reconcileRegistration() }
    @objc private func resolve(_ sender: Any?) { proofDocument.resolveUnresolved() }
}

@MainActor
private final class ProofAppDelegate: NSObject, NSApplicationDelegate {
    private var directory: URL!
    private var a: ProofDocument!
    private var b: ProofDocument!
    private var clone: ProofWindowController?
    private var windows: [ProofWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let base = ProcessInfo.processInfo.environment["NATIVE_PROOF_DIR"] ??
            FileManager.default.temporaryDirectory.appendingPathComponent("folio-native-proof").path
        directory = URL(fileURLWithPath: base, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        a = ProofDocument(scope: "A", directory: directory)
        b = ProofDocument(scope: "B", directory: directory)
        makeMenus()
        let first = ProofWindowController(document: a, viewID: "A-main")
        let second = ProofWindowController(document: b, viewID: "B-main")
        windows = [first, second]
        first.showWindow(nil)
        second.showWindow(nil)
        first.window?.makeKeyAndOrderFront(nil)
        first.window?.makeFirstResponder(first.editor)
        a.log("Fixture directory: \(directory.path)")
        b.log("Fixture directory: \(directory.path)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showCloneA() {
        a.settleTyping()
        if let clone { clone.showWindow(nil); clone.window?.makeKeyAndOrderFront(nil); return }
        let created = ProofWindowController(document: a, viewID: "A-clone")
        clone = created
        created.showWindow(nil)
        created.window?.makeKeyAndOrderFront(nil)
        a.log("A clone attached")
    }

    func closeCloneA() {
        clone?.close()
        clone = nil
    }

    func showDocument(_ scope: String) {
        let selected = scope == "A" ? windows[0] : windows[1]
        selected.showWindow(nil)
        selected.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        (scope == "A" ? a : b).log("Show \(scope) requested; focus switched without changing origin of pending requests")
    }

    @objc private func resetScratch(_ sender: Any?) {
        a.reset()
        b.reset()
    }

    private func makeMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "Native Proof")
        appMenu.addItem(withTitle: "Quit Native Proof", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let reset = fileMenu.addItem(withTitle: "Reset Scratch on Relaunch", action: #selector(resetScratch(_:)), keyEquivalent: "")
        reset.target = self
        fileItem.submenu = fileMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(DocumentTextView.undo(_:)), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: #selector(DocumentTextView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        let showA = windowMenu.addItem(withTitle: "Show Document A", action: #selector(menuShowA(_:)), keyEquivalent: "1")
        showA.target = self
        let showB = windowMenu.addItem(withTitle: "Show Document B", action: #selector(menuShowB(_:)), keyEquivalent: "2")
        showB.target = self
        windowItem.submenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc private func menuShowA(_ sender: Any?) { showDocument("A") }
    @objc private func menuShowB(_ sender: Any?) { showDocument("B") }
}

private let delegate = ProofAppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
