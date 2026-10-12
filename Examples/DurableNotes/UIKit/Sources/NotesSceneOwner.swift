// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import UIKit
import DurableNotesCore

@MainActor final class NotesSceneOwner {
    enum State: String { case opening, active, closing, closed, blocked }
    let id: String
    weak var scene: UIWindowScene?
    weak var app: NotesUIKitApp?
    private let restoring: Bool
    var controller: NotesUIKitController?
    private(set) var session: NotesSession?
    private(set) var state = State.closed
    private(set) var events: [String] = [] {
        didSet {
            guard let app else { return }
            try? JSONEncoder().encode(events).write(to: app.root.appendingPathComponent("Events-\(id).json"),
                options: [.atomic, .completeFileProtection])
        }
    }
    var directory: URL { app!.root.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_")) }
    private var protectedData = UIApplication.shared.isProtectedDataAvailable
    private var storageAvailable = true
    private var foreground = true
    private var closing: Task<Bool, Never>?
    private var opening: Task<Void, Never>?
    private var backgroundLease: UIBackgroundTaskIdentifier = .invalid

    init(id: String, scene: UIWindowScene, app: NotesUIKitApp, restoring: Bool) {
        self.id = id; self.scene = scene; self.app = app; self.restoring = restoring
    }
    func openIfAvailable() async {
        if let closing { _ = await closing.value }
        if let opening { await opening.value; return }
        if session != nil && state == .blocked && foreground && protectedData && storageAvailable {
            guard await close(reason: "retry closure after availability returned") else { return }
        }
        guard session == nil, foreground, protectedData, storageAvailable else { return }
        state = .opening; controller?.lifecycleChanged()
        let operation = Task { @MainActor in await self.performOpen() }
        opening = operation
        await operation.value
        opening = nil
    }
    private func performOpen() async {
        var opened: NotesSession?
        do {
            let root = app!.root
            let registry = root.appendingPathComponent("SceneRegistry.json")
            var known: [String] = []
            if FileManager.default.fileExists(atPath: registry.path) {
                known = try JSONDecoder().decode([String].self, from: Data(contentsOf: registry))
            }
            let restored = restoring || known.contains(id)
            let candidate = try await (restored ? NotesSession.openExisting(at: directory) : NotesSession.open(at: directory))
            opened = candidate
            guard foreground, protectedData, storageAvailable else {
                try await candidate.close(); state = .closed
                events.append("Open drained after lifecycle availability changed")
                controller?.lifecycleChanged(); return
            }
                if !restored {
                    // Another scene can have committed while this open awaited.
                    if FileManager.default.fileExists(atPath: registry.path) {
                        known = try JSONDecoder().decode([String].self, from: Data(contentsOf: registry))
                    }
                    if !known.contains(id) { known.append(id) }
                    try JSONEncoder().encode(known).write(to: registry, options: [.atomic, .completeFileProtection])
                }
                session = candidate
                events.append(restored ? "Restored same document scope" : "Created new scene document")
                try controller?.attach()
                await controller?.refresh()
                try controller?.restoreDraft()
                guard foreground, protectedData, storageAvailable else {
                    try await candidate.close(); session = nil; state = .closed
                    events.append("Opened scope closed before becoming editable")
                    controller?.lifecycleChanged(); return
                }
                state = .active
                app?.sceneReady(self)
        } catch {
            if let opened {
                do { try await opened.close(); session = nil }
                catch { session = opened; events.append("Failed opening retained its unclosed owner: \(error)") }
            }
            state = .blocked
            controller?.showMessage("Open refused; original document preserved: \(error)")
            events.append("Open refused: \(error)")
        }
        controller?.lifecycleChanged()
    }
    func close(reason: String) async -> Bool {
        if let opening { await opening.value }
        if let closing { return await closing.value }
        guard let session else { state = .closed; controller?.lifecycleChanged(); return true }
        state = .closing
        events.append("Closure requested: \(reason)")
        _ = controller?.settleEditing(forLifecycle: true)
        controller?.lifecycleChanged()
        let operation = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            await self.controller?.waitForOperations()
            do {
                try self.controller?.persistDraftIfNeeded()
                try await session.close()
                self.session = nil; self.state = .closed
                self.events.append("Outcome drained and store closed: \(reason)")
                self.controller?.lifecycleChanged()
                return true
            } catch {
                self.state = .blocked
                self.events.append("Closure incomplete; owner retained: \(error)")
                self.controller?.showMessage("Closure incomplete; owner retained: \(error)")
                self.controller?.lifecycleChanged()
                return false
            }
        }
        closing = operation
        let result = await operation.value
        closing = nil
        return result
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
        state = .blocked; controller?.lifecycleChanged()
        endBackgroundLease()
    }
    private func endBackgroundLease() {
        if backgroundLease != .invalid { UIApplication.shared.endBackgroundTask(backgroundLease); backgroundLease = .invalid }
    }
    var mayEdit: Bool { state == .active && protectedData && storageAvailable && foreground }
}
