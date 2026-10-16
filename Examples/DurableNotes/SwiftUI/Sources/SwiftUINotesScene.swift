// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit
import DurableNotesCore
import UndoKit

@MainActor final class SwiftUINotesRegistry: ObservableObject {
    let sessions = HistorySessions()
    var checksStarted = false
    private(set) var ownerIDs: Set<String> = []
    private var scenes: [String: WeakSwiftUINotesOwner] = [:]

    var activeScenes: [SwiftUINotesOwner] { scenes.values.compactMap(\.value) }

    func attach(_ owner: SwiftUINotesOwner) { scenes[owner.id] = WeakSwiftUINotesOwner(owner) }
    func detach(_ id: String) { scenes.removeValue(forKey: id) }

    func loadOwnerIDs(at url: URL) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
    }

    func register(_ id: String, at url: URL) throws {
        var identifiers = try loadOwnerIDs(at: url)
        guard identifiers.insert(id).inserted else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(identifiers.sorted()).write(to: url, options: .atomic)
        ownerIDs = identifiers
    }
}

@MainActor private final class WeakSwiftUINotesOwner {
    weak var value: SwiftUINotesOwner?
    init(_ value: SwiftUINotesOwner) { self.value = value }
}

/// One StateObject per SwiftUI scene. The editor, binding and session live here,
/// outside body reconstruction and navigation destinations.
@MainActor final class SwiftUINotesOwner: ObservableObject {
    private(set) var id: String
    let registry: SwiftUINotesRegistry
    private var attachment: HistoryAttachment?
    let titleEditor = NativeHistoryTextView()
    let bodyEditor = NativeHistoryTextView()
    let scratchEditor = UITextView()
    @Published private(set) var session: HistorySession?
    @Published private(set) var binding: NativeHistoryUIKitBinding?
    private(set) var lease: NotesDocumentLease?
    @Published private(set) var status = "Opening durable note…"
    @Published var showEditor = true
    @Published var editorGeneration = 0
    @Published var navigationPath = NavigationPath()
    private(set) var documentURL: URL
    @Published private(set) var protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
    private var lifecycleTail: Task<Void, Never>?
    private var foreground = true
    weak var windowScene: UIWindowScene?

    init(id: String, registry: SwiftUINotesRegistry) {
        self.id = id
        self.registry = registry
        documentURL = Self.fixtureRoot.appendingPathComponent(id, isDirectory: true)
    }

    static var fixtureRoot: URL {
        let fixture = ProcessInfo.processInfo.environment["UNDOKIT_SWIFTUI_FIXTURE"] ?? "Interactive"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DurableNotesSwiftUI", isDirectory: true)
            .appendingPathComponent(fixture, isDirectory: true)
    }

    func configure(restoredSceneID: String) {
        guard session == nil, id != restoredSceneID else { return }
        registry.detach(id)
        id = restoredSceneID
        documentURL = Self.fixtureRoot.appendingPathComponent(restoredSceneID, isDirectory: true)
        registry.attach(self)
    }

    func open() async {
        await serialize { await self.openNow() }
    }

    private func openNow() async {
        guard foreground, protectedDataAvailable else { updateStatus(); return }
        if let session, session.status.phase != .closed {
            if session.status.phase == .blocked || session.status.phase == .suspended { await session.close() }
            if session.status.phase != .closed {
                if binding == nil { try? await attach(to: session) }
                binding?.isAvailable = foreground && protectedDataAvailable
                updateStatus(); return
            }
        }
        binding?.disconnect(); binding = nil
        let marker = Self.fixtureRoot.appendingPathComponent("SceneRegistry.json")
        let knownIDs: Set<String>
        do { knownIDs = try registry.loadOwnerIDs(at: marker) }
        catch { status = "Scene registry is unreadable; existing data was preserved: \(error)"; return }
        let known = knownIDs.contains(id)
        let existing = known ? HistoryOpenMode.existing : .create
        let lease = self.lease ?? NotesDocumentLease(directory: documentURL)
        self.lease = lease
        let session = await lease.openSession(in: registry.sessions, mode: existing)
        self.session = session
        guard session.status.phase == .ready else { updateStatus(); return }
        do { try await attach(to: session) }
        catch { status = "Editor attachment failed: \(error)"; return }
        if session.status.phase == .ready, !known {
            do { try registry.register(id, at: marker) }
            catch { status = "Scene identity could not be saved: \(error)"; await session.close(); return }
        }
        updateStatus()
    }

    private func attach(to session: HistorySession) async throws {
        guard binding == nil else { return }
        guard let lease else { return }
        attachment = try session.attach(owner: self, statusDidChange: { owner, _ in owner.updateStatus() })
        binding = try await attachment!.bindUIKit(editors: [
            (titleEditor, try lease.field(.title, in: session)),
            (bodyEditor, try lease.field(.body, in: session))], localEditors: [scratchEditor])
    }

    private func render(_ note: Note) {
        for (editor, value) in [(titleEditor, note.title), (bodyEditor, note.body)] {
            let selection = editor.selectedRange
            if editor.text != value { editor.text = value }
            let location = min(selection.location, value.utf16.count)
            editor.selectedRange = NSRange(location: location,
                length: min(selection.length, max(0, value.utf16.count - location)))
        }
    }

    func updateStatus() {
        guard let session else { return }
        status = "History: \(session.status.phase); draft decision: \(session.status.requiresDraftDecision ? "required" : "none"); live transaction: \(binding?.hasLiveTransaction == true)"
    }

    func commit() { _ = binding?.requestCommit() }
    func undo() { Task { _ = await binding?.undoDocument() } }
    func redo() { Task { _ = await binding?.redoDocument() } }
    func disconnectPresentation() { binding?.disconnect() }
    func closeForBackground() async {
        await serialize { await self.closeNow() }
    }

    private func closeNow() async {
        guard session != nil else { return }
        binding?.isAvailable = false
        await binding?.close()
        updateStatus()
    }

    func protectedDataChanged(_ available: Bool) {
        protectedDataAvailable = available
        binding?.isAvailable = foreground && available
        if available { Task { await open() } }
        else { Task { await closeForBackground() } }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        foreground = phase == .active
        binding?.isAvailable = foreground && protectedDataAvailable
        if foreground {
            Task {
                await open()
                recordLifecycle("ForegroundReady.json")
            }
        } else if phase == .background {
            Task {
                await closeForBackground()
                recordLifecycle("BackgroundClosed.json")
            }
        }
    }

    private func recordLifecycle(_ filename: String) {
        guard ProcessInfo.processInfo.environment["UNDOKIT_SWIFTUI_CHECK"] == "1",
              FileManager.default.fileExists(atPath: Self.fixtureRoot.appendingPathComponent("Stage.json").path) else { return }
        if filename == "BackgroundClosed.json", session?.status.phase != .closed { return }
        if filename == "ForegroundReady.json", session?.status.phase != .ready { return }
        let payload = ["sceneID": id, "phase": status]
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: Self.fixtureRoot.appendingPathComponent(filename), options: .atomic)
        }
    }

    private func serialize(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = lifecycleTail
        let next = Task { @MainActor in
            await previous?.value
            await operation()
        }
        lifecycleTail = next
        await next.value
    }

    isolated deinit {
        let id = id
        let registry = registry
        let binding = binding
        let session = session
        Task { @MainActor in
            await binding?.close()
            binding?.disconnect()
            await session?.close()
            registry.detach(id)
        }
    }
}

@MainActor struct SwiftUINotesScene: View {
    @ObservedObject private var registry: SwiftUINotesRegistry
    @StateObject private var owner: SwiftUINotesOwner
    @SceneStorage("durableNotesSwiftUISceneID") private var sceneID = UUID().uuidString
    @Environment(\.scenePhase) private var scenePhase

    init(registry: SwiftUINotesRegistry) {
        self.registry = registry
        _owner = StateObject(wrappedValue: SwiftUINotesOwner(id: UUID().uuidString, registry: registry))
    }

    var body: some View {
        NavigationStack(path: $owner.navigationPath) {
            Group {
                if owner.protectedDataAvailable {
                    Form {
                Section("Durable note · scene \(owner.id.prefix(6))") {
                    Text("A stable scene owner retains the native editor and durable session across SwiftUI body updates.")
                        .font(.footnote)
                    if let binding = owner.binding {
                        if owner.showEditor {
                            NativeHistorySwiftUIEditor(textView: owner.titleEditor)
                                .id(owner.editorGeneration)
                                .frame(height: 48)
                                .accessibilityLabel("Title")
                            NativeHistorySwiftUIEditor(textView: owner.bodyEditor)
                                .id(owner.editorGeneration)
                                .frame(height: 150)
                                .accessibilityLabel("Body")
                                .nativeHistory(binding)
                        } else {
                            Button("Reattach native editor") { owner.showEditor = true }
                        }
                        NativeHistorySwiftUIEditor(textView: owner.scratchEditor)
                            .frame(height: 90)
                            .accessibilityLabel("Local scratch")
                        HStack {
                            SwiftUINotesUndoButtons(status: owner.status).nativeHistory(binding)
                            Button("Commit typing") { owner.commit() }
                        }
                        if owner.session?.snapshot.isSuspended == true {
                            Button("Reconcile accepted outcome") { Task { _ = await owner.session?.reconcile() } }
                        }
                        if binding.status.requiresDraftDecision {
                            HStack {
                                Button("Retry preserved draft") { Task { _ = await binding.retryDraft() } }
                                Button("Discard preserved draft") { Task { _ = await binding.discardDraft() } }
                            }
                        }
                    }
                    Text(owner.status).font(.footnote).accessibilityIdentifier("HistoryStatus")
                }
                Section("SwiftUI lifecycle") {
                    Button("Rebuild editor presentation") { owner.editorGeneration += 1 }
                    Button("Hide editor presentation") { owner.showEditor = false }
                    NavigationLink("Open navigation detail", value: "history-detail")
                    Button("Durable Undo") { owner.undo() }
                    Button("Durable Redo") { owner.redo() }
                    Button("Close and reopen") {
                        Task { await owner.closeForBackground(); await owner.open() }
                    }
                }
            }
                } else {
                    ContentUnavailableView("Document hidden", systemImage: "lock.fill",
                        description: Text("Protected data is unavailable. The existing history owner is retained for safe closure."))
                }
            }
            .navigationTitle("Durable Notes")
            .navigationDestination(for: String.self) { route in
                if route == "history-detail" { SwiftUINotesDetail(owner: owner) }
            }
        }
        .background(SwiftUINotesWindowAnchor(owner: owner).frame(width: 0, height: 0).accessibilityHidden(true))
        .task {
            owner.configure(restoredSceneID: sceneID)
            registry.attach(owner)
            await owner.open()
            if ProcessInfo.processInfo.environment["UNDOKIT_SWIFTUI_CHECK"] == "1", !registry.checksStarted {
                registry.checksStarted = true
                await SwiftUIChecks.run(owner: owner)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            owner.scenePhaseChanged(phase)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            owner.protectedDataChanged(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            owner.protectedDataChanged(true)
        }
    }
}

@MainActor private struct SwiftUINotesWindowAnchor: UIViewRepresentable {
    let owner: SwiftUINotesOwner
    func makeUIView(context: Context) -> SwiftUINotesWindowAnchorView {
        let view = SwiftUINotesWindowAnchorView()
        view.sceneDidChange = { [weak owner] in owner?.windowScene = $0 }
        return view
    }
    func updateUIView(_ view: SwiftUINotesWindowAnchorView, context: Context) {
        view.sceneDidChange = { [weak owner] in owner?.windowScene = $0 }
        owner.windowScene = view.window?.windowScene
    }
}

@MainActor private final class SwiftUINotesWindowAnchorView: UIView {
    var sceneDidChange: ((UIWindowScene?) -> Void)?
    override func didMoveToWindow() { sceneDidChange?(window?.windowScene) }
}

@MainActor private struct SwiftUINotesUndoButtons: View {
    let status: String
    @Environment(\.nativeHistoryUndoManager) private var undoManager
    @State private var canUndo = false
    @State private var canRedo = false

    var body: some View {
        HStack {
            Button("Undo") { undoManager?.undo() }
                .disabled(!canUndo)
                .accessibilityIdentifier("SwiftUIUndoButton")
            Button("Redo") { undoManager?.redo() }
                .disabled(!canRedo)
                .accessibilityIdentifier("SwiftUIRedoButton")
        }
        .accessibilityValue(status)
        .onAppear { refreshEligibility() }
        .onChange(of: undoManager.map(ObjectIdentifier.init)) { _, _ in refreshEligibility() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerCheckpoint, object: undoManager)
            .receive(on: RunLoop.main)) { _ in refreshEligibility() }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidBeginEditingNotification)
            .receive(on: RunLoop.main)) { _ in refreshEligibility() }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidEndEditingNotification)
            .receive(on: RunLoop.main)) { _ in refreshEligibility() }
    }

    private func refreshEligibility() {
        canUndo = undoManager?.canUndo == true
        canRedo = undoManager?.canRedo == true
    }
}

@MainActor private struct SwiftUINotesDetail: View {
    @ObservedObject var owner: SwiftUINotesOwner
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The root scene owner remains alive while this destination is presented.")
            Text(owner.status).accessibilityIdentifier("DetailHistoryStatus")
            Button("Return to editor") { dismiss() }
        }
        .padding()
        .navigationTitle("History detail")
    }
}
