// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import UIKit

@main @MainActor final class NotesUIKitApp: UIResponder, UIApplicationDelegate {
    var owners: [String: NotesSceneOwner] = [:]
    var checksStarted = false
    var events: [String] = []
    var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let fixture = ProcessInfo.processInfo.environment["UNDOKIT_UIKIT_FIXTURE"] ?? "Interactive"
        return base.appendingPathComponent("DurableNotesUIKit").appendingPathComponent(fixture)
    }
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Durable Notes", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = NotesSceneDelegate.self
        return configuration
    }
    func applicationProtectedDataWillBecomeUnavailable(_ application: UIApplication) {
        events.append("UIKit protected data will become unavailable")
        for owner in owners.values { owner.setProtectedDataAvailable(false) }
    }
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        events.append("UIKit protected data became available")
        for owner in owners.values { owner.setProtectedDataAvailable(true) }
    }
    func requestNewScene() {
        guard UIApplication.shared.supportsMultipleScenes else {
            events.append("Multiple scenes unavailable on this device")
            return
        }
        let activity = NSUserActivity(activityType: "app.foliosuite.UndoKit.DurableNotes.new")
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil) { [weak self] error in
            Task { @MainActor in
                self?.events.append("Scene activation rejected: \(error)")
                self?.owners.values.forEach { $0.controller?.showMessage("New scene rejected: \(error.localizedDescription)") }
            }
        }
    }
    func finishSample() {
        Task { @MainActor in
            var closed = true
            for owner in owners.values { closed = await owner.close(reason: "explicit finish") && closed }
            if closed { exit(EXIT_SUCCESS) }
            else { owners.values.forEach { $0.controller?.showMessage("Finish refused: an owner still requires recovery") } }
        }
    }
    func sceneReady(_ owner: NotesSceneOwner) {
        guard ProcessInfo.processInfo.environment["UNDOKIT_UIKIT_CHECK"] == "1", !checksStarted else { return }
        checksStarted = true
        Task { @MainActor in
            do { try await UIKitChecks.run(first: owner, app: self) }
            catch {
                var closed = true
                for owner in self.owners.values {
                    // A failed fixture must release its deterministic test-only
                    // delay before asking the real owner to drain and close.
                    await owner.session?.resumeDelivery()
                    closed = await owner.close(reason: "failed native check cleanup") && closed
                }
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try? Data(String(describing: error).utf8).write(to: root.appendingPathComponent("Failure.txt"), options: .atomic)
                owner.controller?.showMessage("Native check failed: \(error)")
                if closed { exit(EXIT_FAILURE) }
            }
        }
    }
}

@MainActor final class NotesSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var owner: NotesSceneOwner?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene, let app = UIApplication.shared.delegate as? NotesUIKitApp else { return }
        let id = session.persistentIdentifier
        let activity = session.stateRestorationActivity
        let restoring = activity?.userInfo?["fixture"] as? String == app.root.lastPathComponent
        let owner = app.owners[id] ?? NotesSceneOwner(id: id, scene: scene, app: app, restoring: restoring)
        owner.scene = scene; app.owners[id] = owner; self.owner = owner
        let controller = owner.controller ?? NotesUIKitController(owner: owner)
        owner.controller = controller
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: controller)
        self.window = window; window.makeKeyAndVisible()
        Task { await owner.openIfAvailable() }
    }
    func sceneDidEnterBackground(_ scene: UIScene) { owner?.enteredBackground() }
    func sceneWillEnterForeground(_ scene: UIScene) { owner?.enteredForeground() }
    func sceneDidDisconnect(_ scene: UIScene) { owner?.disconnected(); window?.isHidden = true; window = nil }
    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        let activity = NSUserActivity(activityType: "app.foliosuite.UndoKit.DurableNotes.restore")
        activity.userInfo = ["sceneID": scene.session.persistentIdentifier,
            "fixture": owner?.app?.root.lastPathComponent ?? "Interactive"]
        return activity
    }
}
