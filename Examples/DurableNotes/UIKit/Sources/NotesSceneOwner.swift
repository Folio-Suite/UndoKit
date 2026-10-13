// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import UIKit
import DurableNotesCore
import UndoKit

/// Thin platform adapter. The app-owned framework collection retains recovery leases.
@MainActor final class NotesSceneOwner {
    enum State: String { case opening, active, closing, closed, blocked }
    let id: String
    weak var scene: UIWindowScene?
    weak var app: NotesUIKitApp?
    weak var controller: NotesUIKitController?
    private let restoring: Bool
    private(set) var session: NativeHistorySession<NotesDocumentLease>?
    private(set) var lease: NotesDocumentLease?
    private(set) var events: [String] = [] {
        didSet {
            guard let app else { return }
            try? JSONEncoder().encode(events).write(to: app.root.appendingPathComponent("Events-\(id).json"),
                options: [.atomic, .completeFileProtection])
        }
    }
    var directory: URL { app!.root.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_"), isDirectory: true) }
    private var protectedData = UIApplication.shared.isProtectedDataAvailable
    private var storageAvailable = true
    private var foreground = true
    private var backgroundLease: UIBackgroundTaskIdentifier = .invalid
    var state: State {
        switch session?.status.phase {
        case .opening: .opening
        case .ready, .busy: .active
        case .closing: .closing
        case .blocked, .suspended: .blocked
        case .closed, nil: .closed
        }
    }
    init(id: String, scene: UIWindowScene, app: NotesUIKitApp, restoring: Bool) {
        self.id = id; self.scene = scene; self.app = app; self.restoring = restoring
    }
    func openIfAvailable() async {
        guard foreground, protectedData, storageAvailable, let app else { return }
        if let session {
            if session.status.phase == .closed { await app.sessions.reopen(session) }
            controller?.lifecycleChanged()
            return
        }
        do {
            let registry = app.root.appendingPathComponent("SceneRegistry.json")
            var known = FileManager.default.fileExists(atPath: registry.path)
                ? try JSONDecoder().decode([String].self, from: Data(contentsOf: registry)) : []
            let restored = restoring || known.contains(id)
            let lease = app.domainLease(at: directory)
            self.lease = lease
            let session = await app.sessions.open(documentURL: directory, mode: restored ? .existing : .create,
                codec: .json(), draftURL: directory.appendingPathComponent("Draft.json")) { lease }
            self.session = session
            try controller?.attach()
            guard session.status.phase == .ready else {
                events.append("Open refused; original document preserved")
                controller?.showMessage("Open refused: \(String(describing: session.status.issue))"); return
            }
            if !restored {
                if FileManager.default.fileExists(atPath: registry.path) {
                    known = try JSONDecoder().decode([String].self, from: Data(contentsOf: registry))
                }
                if !known.contains(id) { known.append(id) }
                try JSONEncoder().encode(known).write(to: registry, options: [.atomic, .completeFileProtection])
            }
            events.append(restored ? "Restored same document scope" : "Created new scene document")
            if foreground, protectedData, storageAvailable { app.sceneReady(self) }
            else { _ = await close(reason: "availability changed during open") }
        } catch {
            controller?.showMessage("Open refused; original document preserved: \(error)")
            _ = await close(reason: "failed scene attachment")
        }
        controller?.lifecycleChanged()
    }
    func close(reason: String) async -> Bool {
        guard let session else { return true }
        events.append("Closure requested: \(reason)")
        if let binding = controller?.binding { await binding.close() }
        else { await session.close() }
        let closed = session.status.phase == .closed
        events.append(closed ? "Outcome drained and store closed: \(reason)" : "Closure incomplete; owner retained: \(reason)")
        controller?.lifecycleChanged()
        return closed
    }
    func enteredBackground() {
        foreground = false; events.append("UIKit scene entered background")
        if backgroundLease == .invalid {
            backgroundLease = UIApplication.shared.beginBackgroundTask(withName: "Durable note close") { [weak self] in
                self?.backgroundExpired()
            }
        }
        Task { @MainActor in
            _ = await close(reason: "background")
            endBackgroundLease()
            if foreground { await openIfAvailable() }
        }
    }
    func enteredForeground() {
        foreground = true; events.append("UIKit scene will enter foreground")
        protectedData = UIApplication.shared.isProtectedDataAvailable
        Task { await openIfAvailable() }
    }
    func disconnected() {
        foreground = false; events.append("UIKit scene disconnected")
        controller?.binding?.disconnect()
        controller = nil
        app?.owners.removeValue(forKey: id)
        Task { _ = await close(reason: "scene disconnect") }
    }
    func setProtectedDataAvailable(_ available: Bool) {
        protectedData = available
        events.append("Protected-data observation: \(available)")
        controller?.view.isHidden = !available
        if available { Task { await openIfAvailable() } }
        else { Task { _ = await close(reason: "protected data unavailable") } }
    }
    func setStorageAvailable(_ available: Bool) async {
        storageAvailable = available
        if !available { _ = await close(reason: "storage unavailable") }
        else { await openIfAvailable() }
    }
    func backgroundExpired() {
        events.append("Background budget expired; closure not certified")
        controller?.binding?.isAvailable = false; controller?.lifecycleChanged()
        endBackgroundLease()
    }
    private func endBackgroundLease() {
        if backgroundLease != .invalid { UIApplication.shared.endBackgroundTask(backgroundLease); backgroundLease = .invalid }
    }
    var mayEdit: Bool { protectedData && storageAvailable && foreground && session?.status.phase != .closed }
}
