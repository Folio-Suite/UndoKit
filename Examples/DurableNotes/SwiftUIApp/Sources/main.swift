// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import AppKit
import Combine
import DurableNotesCore
import SwiftUI
import UndoKit

@MainActor final class DurableNotesSwiftUIApplicationOwner: ObservableObject {
    let sessions = NativeHistorySessions<NotesDocumentLease>()
    let root: URL
    private let registry: NotesDocumentRegistry
    private var leases: [String: NotesDocumentLease] = [:]
    private var documents: [String: DurableNotesSwiftUIDocumentOwner] = [:]

    init() {
        if let supplied = ProcessInfo.processInfo.environment["UNDOKIT_SWIFTUI_NOTES_ROOT"] {
            root = URL(fileURLWithPath: supplied, isDirectory: true)
        } else {
            root = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))?.appendingPathComponent("UndoKit-DurableNotes-SwiftUI", isDirectory: true)
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("UndoKit-DurableNotes-SwiftUI", isDirectory: true)
        }
        registry = NotesDocumentRegistry(root: root)
    }

    func document(_ identifier: String) -> DurableNotesSwiftUIDocumentOwner {
        if let document = documents[identifier] { return document }
        let directory = root.appendingPathComponent(identifier, isDirectory: true)
        let lease = leases[identifier] ?? NotesDocumentLease(directory: directory)
        leases[identifier] = lease
        let document = DurableNotesSwiftUIDocumentOwner(identifier: identifier, directory: directory,
            sessions: sessions, registry: registry, lease: lease)
        documents[identifier] = document
        return document
    }

    var allDocuments: [DurableNotesSwiftUIDocumentOwner] { Array(documents.values) }

    func releasePresentation(_ identifier: String) {
        guard let document = documents.removeValue(forKey: identifier) else { return }
        let session = document.session
        document.binding?.disconnect()
        Task { @MainActor in await session?.close() }
    }
}

@MainActor final class DurableNotesSwiftUIDocumentOwner: ObservableObject {
    let identifier: String
    let directory: URL
    let titleEditor = NativeHistoryAppKitTextView()
    let bodyEditor = NativeHistoryAppKitTextView()
    let scratchEditor = NativeHistoryAppKitTextView()
    @Published private(set) var summary = "Opening document…"
    @Published private(set) var refreshToken = 0
    private let sessions: NativeHistorySessions<NotesDocumentLease>
    let lease: NotesDocumentLease
    private let registry: NotesDocumentRegistry
    weak var window: NSWindow?
    @Published var presentationGeneration = 0
    var scratch: NativeHistoryAppKitTextView { scratchEditor }
    private var uiOperation: Task<Void, Never>?
    private var opening = false
    private(set) var session: NativeHistorySession<NotesDocumentLease>?
    private(set) var binding: NativeHistoryAppKitBinding<NotesDocumentLease>?

    init(identifier: String, directory: URL, sessions: NativeHistorySessions<NotesDocumentLease>, registry: NotesDocumentRegistry, lease: NotesDocumentLease) {
        self.identifier = identifier
        self.directory = directory
        self.sessions = sessions
        self.registry = registry
        self.lease = lease
        for editor in [titleEditor, bodyEditor, scratchEditor] {
            editor.isRichText = false
            editor.allowsUndo = true
            editor.isVerticallyResizable = true
            editor.isHorizontallyResizable = false
            editor.autoresizingMask = [.width]
            editor.textContainer?.widthTracksTextView = true
        }
    }

    func openIfNeeded() async {
        guard session == nil, !opening else { return }
        opening = true
        defer { opening = false }
        let mode: NativeHistoryOpenMode
        do { mode = try registry.openMode(for: directory) }
        catch {
            summary = "Document discovery failed; no files were changed. \(error)"
            refreshToken += 1
            return
        }
        let session = await sessions.open(documentURL: directory, mode: mode,
            codec: .json(), draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        self.session = session
        do {
            binding = try session.connectAppKit(owner: self, editors: [titleEditor, bodyEditor],
                localEditors: [scratchEditor], actionName: "Edit Note",
                captureDraft: { owner in
                    NativeDraftCapture(value: Note(title: owner.titleEditor.string, body: owner.bodyEditor.string),
                        isComposing: owner.titleEditor.hasMarkedText() || owner.bodyEditor.hasMarkedText())
                },
                draftDidChange: { owner, note in owner.render(note) },
                statusDidChange: { owner, _ in owner.updateSummary() })
            await refreshReadout()
        } catch {
            summary = "Editor connection failed; session ownership remains retained. \(error)"
            refreshToken += 1
        }
    }

    private func render(_ note: Note) {
        render(note.title, in: titleEditor)
        render(note.body, in: bodyEditor)
        refreshToken += 1
    }

    private func render(_ value: String, in editor: NSTextView) {
        guard editor.string != value else { return }
        let selection = editor.selectedRange()
        editor.string = value
        let location = min(selection.location, value.utf16.count)
        editor.setSelectedRange(NSRange(location: location,
            length: min(selection.length, max(0, value.utf16.count - location))))
    }

    private func updateSummary() {
        guard let session else { return }
        let editable = binding?.permitsEditing ?? (session.status.phase == .ready)
        for editor in [titleEditor, bodyEditor] where !editor.hasMarkedText() {
            editor.isEditable = editable
        }
        summary = "\(identifier) · \(session.status.phase) · \(session.status.requiresDraftDecision ? "Draft decision required" : "")"
        refreshToken += 1
    }

    func refreshReadout() async {
        do {
            let readout = try await lease.read()
            summary = "\(identifier) · \(session?.status.phase ?? .opening) · applications \(readout.applicationCount) · receipts \(readout.receiptCount)"
        } catch {
            updateSummary()
        }
        refreshToken += 1
    }

    func read() async throws -> NotesReadout { try await lease.read() }
    func waitForOperations() async { await uiOperation?.value; await binding?.waitForOperations() }
    func apply(title: String, body: String) {
        guard let binding else { return }
        uiOperation = Task { @MainActor [weak self] in
            _ = await binding.applyDraft(Note(title: title, body: body))
            await self?.refreshReadout()
        }
    }
    func reopenSession() async throws {
        guard let binding, let session else { return }
        await binding.close()
        guard session.status.phase == .closed else { return }
        await sessions.reopen(session)
        binding.isAvailable = session.status.phase == .ready
        await refreshReadout()
    }

    func applyExample() {
        guard let binding else { return }
        uiOperation = Task { @MainActor [weak self] in
            _ = await binding.applyDraft(Note(title: "Shopping", body: "Tea and bread"))
            await self?.refreshReadout()
        }
    }

    func commit() {
        guard let binding else { return }
        uiOperation = Task { @MainActor [weak self] in
            _ = await binding.commit()
            await self?.refreshReadout()
        }
    }

    func retryDraft() {
        guard let binding else { return }
        uiOperation = Task { @MainActor [weak self] in
            _ = await binding.retryDraft()
            await self?.refreshReadout()
        }
    }

    func discardDraft() {
        guard let binding else { return }
        uiOperation = Task { @MainActor [weak self] in
            _ = await binding.discardDraft()
            await self?.refreshReadout()
        }
    }

    func rejectNext() {
        let lease = lease
        uiOperation = Task { @MainActor [weak self] in
            await lease.rejectNextDelivery()
            self?.summary = "Next semantic delivery will be authoritatively rejected."
            self?.refreshToken += 1
        }
    }

    func delayNext() {
        let lease = lease
        uiOperation = Task { @MainActor [weak self] in
            await lease.delayNextDelivery()
            self?.summary = "Next semantic delivery is waiting for Release delayed outcome."
            self?.refreshToken += 1
        }
    }

    func releaseDelayed() {
        let lease = lease
        uiOperation = Task { @MainActor [weak self] in await lease.resumeDelivery(); await self?.refreshReadout() }
    }

    func reopen() {
        guard let session, let binding else { return }
        let sessions = sessions
        uiOperation = Task { @MainActor [weak self] in
            await binding.close()
            guard session.status.phase == .closed else { await self?.refreshReadout(); return }
            await sessions.reopen(session)
            binding.isAvailable = session.status.phase == .ready
            await self?.refreshReadout()
        }
    }
}

@MainActor struct DurableNotesSwiftUIWindow: View {
    @ObservedObject var document: DurableNotesSwiftUIDocumentOwner
    let openDocument: @MainActor (String) -> Void

    init(application: DurableNotesSwiftUIApplicationOwner, documentID: String,
        openDocument: @escaping @MainActor (String) -> Void) {
        document = application.document(documentID)
        self.openDocument = openDocument
    }

    var body: some View {
        Group {
            if let binding = document.binding {
                DurableNotesSwiftUIEditorPane(document: document, openDocument: openDocument)
                    .nativeHistory(binding)
            } else {
                ProgressView(document.summary).frame(minWidth: 600, minHeight: 500)
            }
        }
        .task { await document.openIfNeeded() }
        .frame(minWidth: 620, minHeight: 680)
    }
}

@MainActor private struct DurableNotesSwiftUIEditorPane: View {
    @ObservedObject var document: DurableNotesSwiftUIDocumentOwner
    @Environment(\.nativeHistoryUndoManager) private var undoManager
    let openDocument: @MainActor (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Durable Notes")
                .font(.title2)
            Text("Standard NSTextView input. Cmd-Z routes through the focused editor; typing stays live until Commit.")
                .foregroundStyle(.secondary)
            Group {
                Text("Title")
                NativeHistorySwiftUIEditor(textView: document.titleEditor)
                    .id("title-\(document.presentationGeneration)")
                    .frame(height: 44)
                Text("Body")
                NativeHistorySwiftUIEditor(textView: document.bodyEditor)
                    .id("body-\(document.presentationGeneration)")
                    .frame(minHeight: 150, maxHeight: .infinity)
                Text("Local scratch")
                NativeHistorySwiftUIEditor(textView: document.scratchEditor)
                    .id("scratch-\(document.presentationGeneration)")
                    .frame(height: 100)
            }
            HStack {
                Button("Undo") { undoManager?.undo() }
                    .disabled(undoManager?.canUndo != true)
                Button("Redo") { undoManager?.redo() }
                    .disabled(undoManager?.canRedo != true)
                Button("Commit typing") { document.commit() }
                    .disabled(document.binding?.permitsEditing != true)
                Button("Apply grouped example") { document.applyExample() }
                    .disabled(document.binding?.permitsEditing != true)
            }
            HStack {
                Button("Reject next edit") { document.rejectNext() }
                Button("Delay next edit") { document.delayNext() }
                Button("Release delayed outcome") { document.releaseDelayed() }
                Button("Close / reopen") { document.reopen() }
            }
            HStack {
                Button("Retry retained draft") { document.retryDraft() }
                Button("Discard retained draft") { document.discardDraft() }
                Button("Rebuild SwiftUI editor views") { document.presentationGeneration += 1 }
                Button("Open independent document window") { openDocument("Document-\(UUID().uuidString)") }
            }
            #if DEBUG
            Button("Accept then fail history finalization") {
                guard let binding = document.binding else { return }
                Task { @MainActor [weak document = document] in
                    _ = await binding.demonstrateFinalizationFailure()
                    await document?.refreshReadout()
                }
            }
            #endif
            Text(document.summary)
                .font(.callout.monospaced())
                .accessibilityIdentifier("DurableNotesStatus")
                .id(document.refreshToken)
        }
        .padding(18)
    }
}

@MainActor final class DurableNotesSwiftUIApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let application = DurableNotesSwiftUIApplicationOwner()
    private var windows: [String: NSWindowController] = [:]
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        openDocument("Document-A")
        openDocument("Document-B")
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--native-check") {
            Task { @MainActor in
                do {
                    let a = application.document("Document-A")
                    let b = application.document("Document-B")
                    for _ in 0..<100 {
                        if a.binding != nil && b.binding != nil { break }
                        try await Task.sleep(for: .milliseconds(40))
                    }
                    try await SwiftUINativeChecks.run(a: a, b: b, root: application.root)
                    await a.binding?.close(); await b.binding?.close()
                    exit(EXIT_SUCCESS)
                } catch {
                    try? Data(String(describing: error).utf8).write(to: application.root.appendingPathComponent("NativeFailure.txt"))
                    NSLog("SwiftUI native check failed: %@", String(describing: error))
                    exit(EXIT_FAILURE)
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let identifier = windows.first(where: { $0.value.window === window })?.key else { return }
        // Remove the SwiftUI graph as well as our owner registry. A cached representation
        // must not keep a closed document's native editors alive during blocked recovery.
        if let host = window.contentView as? NSHostingView<AnyView> { host.rootView = AnyView(EmptyView()) }
        window.contentView = nil
        windows.removeValue(forKey: identifier)
        application.releasePresentation(identifier)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            for document in application.allDocuments {
                await document.binding?.close()
                guard document.session?.status.phase == .closed else {
                    terminating = false
                    sender.reply(toApplicationShouldTerminate: false)
                    let alert = NSAlert()
                    alert.messageText = "Document recovery still needs attention"
                    alert.informativeText = "Durable Notes kept the document owner open because complete closure was not confirmed."
                    alert.runModal()
                    return
                }
            }
            await application.sessions.closeAll()
            guard application.sessions.entries.allSatisfy({ $0.status.phase == .closed }) else {
                terminating = false
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.messageText = "A closed window still owns recovery evidence"
                alert.informativeText = "Reopen the document from File to resolve its retained draft before quitting."
                alert.runModal()
                return
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func openDocument(_ identifier: String) {
        if let existing = windows[identifier] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Durable Notes SwiftUI — \(identifier)"
        window.delegate = self
        application.document(identifier).window = window
        window.isReleasedWhenClosed = false
        let open: @MainActor (String) -> Void = { [weak self] value in self?.openDocument(value) }
        window.contentView = NSHostingView(rootView: AnyView(DurableNotesSwiftUIWindow(application: application,
            documentID: identifier, openDocument: open)))
        let controller = NSWindowController(window: window)
        windows[identifier] = controller
        controller.showWindow(nil)
    }

    @objc private func reopenDocumentA(_ sender: Any?) { openDocument("Document-A") }
    @objc private func reopenDocumentB(_ sender: Any?) { openDocument("Document-B") }

    private func installMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Durable Notes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
        let openA = fileMenu.addItem(withTitle: "Open Document A", action: #selector(reopenDocumentA(_:)), keyEquivalent: "")
        openA.target = self
        let openB = fileMenu.addItem(withTitle: "Open Document B", action: #selector(reopenDocumentB(_:)), keyEquivalent: "")
        openB.target = self
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = DurableNotesSwiftUIApplicationDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
