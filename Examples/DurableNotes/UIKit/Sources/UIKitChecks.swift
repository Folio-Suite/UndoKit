// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import UIKit
import DurableNotesCore
import UndoKit
import Darwin
import MachO

@MainActor enum UIKitChecks {
    struct Report: Codable {
        let runtime: String
        let model: String
        let architecture: String
        let installedRuntime: String
        let installedResources: String
        let sceneIDs: [String]
        let observations: [String]
        let events: [String: [String]]
        let fileProtectionObservation: String
        let limitations: [String]
    }
    enum CheckFailure: Error { case observation(String) }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure.observation(message) }
    }
    private static func waitUntil(_ message: String, timeout: TimeInterval = 30,
                                  condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw CheckFailure.observation(message) }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    private static func activate(_ owner: NotesSceneOwner, app: NotesUIKitApp) async throws {
        guard let sceneSession = UIApplication.shared.openSessions.first(where: { $0.persistentIdentifier == owner.id }) else {
            throw CheckFailure.observation("Persistent scene session was lost")
        }
        UIApplication.shared.requestSceneSessionActivation(sceneSession, userActivity: nil, options: nil) { error in
            Task { @MainActor in app.events.append("Existing scene activation rejected: \(error)") }
        }
        try await waitUntil("Existing scene did not restore; \(app.events)") {
            owner.state == .active && owner.scene?.activationState == .foregroundActive
        }
    }
    static func run(first: NotesSceneOwner, app: NotesUIKitApp) async throws {
        var observations: [String] = []
        let runtime = (0..<_dyld_image_count()).compactMap { index -> String? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            let path = String(cString: name)
            return path.hasSuffix("/UndoKit.framework/UndoKit") ? URL(fileURLWithPath: path).standardizedFileURL.path : nil
        }
        try require(runtime.count == 1 && runtime[0].hasPrefix(Bundle.main.bundlePath + "/Frameworks/"),
            "Expected exactly one installed UndoKit runtime; images=\(runtime); bundle=\(Bundle.main.bundlePath)")
        let resources = Bundle.main.bundleURL.appendingPathComponent("UndoKit_UndoKit.bundle")
        try require(FileManager.default.fileExists(atPath: resources.appendingPathComponent("History.momd").path)
            && FileManager.default.fileExists(atPath: resources.appendingPathComponent("PrivacyInfo.xcprivacy").path),
            "Installed package model/privacy resources are missing")
        guard let controller = first.controller, let session = first.session else {
            throw CheckFailure.observation("Missing live UIWindowScene owner")
        }
        try require((await session.read()).note == Note(), "Checks need a fresh fixture")
        controller.apply(title: "Shopping", body: "Tea and bread")
        await controller.waitForOperations()
        try require((await session.read()).applicationCount == 1, "Grouped native edit did not apply once")
        controller.view.endEditing(true)
        controller.undoButton.sendActions(for: .touchUpInside)
        await controller.waitForOperations()
        try require((await session.read()).note == Note(), "Toolbar Undo without an editor first responder failed")
        controller.redoButton.sendActions(for: .touchUpInside)
        await controller.waitForOperations()
        try require((await session.read()).note == Note(title: "Shopping", body: "Tea and bread"), "Toolbar Redo without focus failed")
        controller.bodyEditor.becomeFirstResponder()
        try require(UIApplication.shared.sendAction(#selector(NotesTextView.notesUndo(_:)), to: nil,
            from: controller, for: nil), "UIKit responder chain did not route Undo")
        await controller.waitForOperations()
        try require((await session.read()).note == Note(), "UIKit Undo did not reverse both fields")
        try require(UIApplication.shared.sendAction(#selector(NotesTextView.notesRedo(_:)), to: nil,
            from: controller, for: nil), "UIKit responder chain did not route Redo")
        await controller.waitForOperations()
        try require((await session.read()).note == Note(title: "Shopping", body: "Tea and bread"), "UIKit Redo failed")
        observations.append("UIControl toolbar Undo/Redo works without editor focus; focused UITextView UIResponder Undo/Redo reverses the complete two-member group.")

        let beforeTyping = await session.read().applicationCount
        controller.bodyEditor.selectedRange = NSRange(location: controller.bodyEditor.text.utf16.count, length: 0)
        controller.bodyEditor.insertText(" and")
        try await Task.sleep(for: .milliseconds(60))
        controller.bodyEditor.insertText(" milk")
        try await Task.sleep(for: .milliseconds(60))
        try require((await session.read()).applicationCount == beforeTyping, "Native typing event groups committed prematurely")
        _ = UIApplication.shared.sendAction(#selector(NotesTextView.notesUndo(_:)), to: nil, from: controller, for: nil)
        await controller.waitForOperations()
        try require((await session.read()).note.body == "Tea and bread", "Typing Undo did not settle and reverse the entire run")
        try require((await session.read()).applicationCount == beforeTyping + 2, "Typing group was split")
        observations.append("Actual UITextView insertions across event turns stay provisional; one native Undo settles and reverses the typing run.")

        controller.bodyEditor.selectedRange = NSRange(location: controller.bodyEditor.text.utf16.count, length: 0)
        controller.bodyEditor.setMarkedText(" composition", selectedRange: NSRange(location: 12, length: 0))
        try require(controller.bodyEditor.markedTextRange != nil, "UITextView did not form a marked range")
        let beforeMarked = await session.read().applicationCount
        _ = UIApplication.shared.sendAction(#selector(NotesTextView.notesUndo(_:)), to: nil, from: controller, for: nil)
        try await Task.sleep(for: .milliseconds(60))
        let afterMarkedAttempt = await session.read()
        try require(controller.router.pendingInvocationID == nil && afterMarkedAttempt.applicationCount == beforeMarked,
            "Marked text entered semantic Undo before settlement")
        controller.bodyEditor.unmarkText()
        _ = controller.settleEditing(); await controller.waitForOperations()
        try require((await session.read()).note.body == "Tea and bread composition", "Settled marked text was lost")
        _ = UIApplication.shared.sendAction(#selector(NotesTextView.notesUndo(_:)), to: nil, from: controller, for: nil)
        await controller.waitForOperations()
        observations.append("Real UITextInput marked text defers semantic Undo, then commits as one undoable change after unmarking.")

        await session.rejectNextDelivery()
        controller.bodyEditor.selectedRange = NSRange(location: controller.bodyEditor.text.utf16.count, length: 0)
        controller.bodyEditor.insertText(" rejected")
        let beforeRejected = await session.read().applicationCount
        _ = UIApplication.shared.sendAction(#selector(NotesTextView.notesUndo(_:)), to: nil, from: controller, for: nil)
        await controller.waitForOperations()
        try require(controller.lastResult == .rejected, "Queued typing was not rejected")
        try require((await session.read()).applicationCount == beforeRejected, "Rejected settlement fell through to earlier Undo")
        try require(controller.bodyEditor.text.hasSuffix(" rejected"), "Rejected provisional draft was discarded")
        await controller.discardDraft()
        observations.append("Rejected typing preserves an explicit uncommitted draft; that same Undo invocation does not reverse preceding accepted history.")

        controller.scratch.becomeFirstResponder(); controller.scratch.localHistory.removeAllActions()
        let beforeLocal = await session.read().applicationCount
        controller.undoButton.sendActions(for: .touchUpInside)
        try require((await session.read()).applicationCount == beforeLocal, "Empty local history fell through to document toolbar Undo")
        let local = controller.scratch.localHistory; local.groupsByEvent = false; local.beginUndoGrouping()
        controller.scratch.insertText("local"); local.endUndoGrouping()
        _ = UIApplication.shared.sendAction(#selector(NotesTextView.notesUndo(_:)), to: nil, from: controller, for: nil)
        try await Task.sleep(for: .milliseconds(60))
        try require(controller.scratch.text.isEmpty,
            "Local UIKit text Undo failed; text=\(controller.scratch.text ?? "nil"); localUndo=\(local.canUndo); redo=\(local.canRedo); focus=\(controller.scratch.isFirstResponder)")
        try require((await session.read()).applicationCount == beforeLocal, "Local text mutated the domain")
        observations.append("Focused local UITextView consumes keyboard and toolbar Undo, including empty local history, independently of document history.")

        controller.bodyEditor.becomeFirstResponder()
        await session.delayNextDelivery(); controller.apply(title: "Delayed", body: "Pending effect")
        let delayDeadline = Date().addingTimeInterval(10)
        while !(await session.isDeliveryDelayed()) && Date() < delayDeadline { try await Task.sleep(for: .milliseconds(40)) }
        try require(await session.isDeliveryDelayed(), "Controlled delayed delivery did not start")
        let pendingText = controller.bodyEditor.text
        controller.bodyEditor.insertText(" blocked")
        _ = UIApplication.shared.sendAction(#selector(NotesTextView.notesUndo(_:)), to: nil, from: controller, for: nil)
        try require(controller.router.isEditingBlocked && controller.bodyEditor.text == pendingText,
            "Pending native editing barrier allowed another semantic input")
        try require(controller.bodyEditor.isFirstResponder, "Pending barrier lost native text focus")
        var peer: NotesSceneOwner?
        if UIApplication.shared.supportsMultipleScenes {
            app.requestNewScene()
            try await waitUntil("Actual iPad scene activation failed; \(app.events)") {
                app.owners.values.contains { $0.id != first.id && $0.state == .active && $0.scene?.activationState == .foregroundActive }
            }
            peer = app.owners.values.first { $0.id != first.id && $0.state == .active && $0.scene?.activationState == .foregroundActive }
            guard let peer, let peerController = peer.controller, let peerSession = peer.session else {
                throw CheckFailure.observation("Second UIWindowScene lacks its independent owner")
            }
            try require(UIApplication.shared.connectedScenes.count >= 2 && peerSession.engine.snapshot.scope != session.engine.snapshot.scope,
                "iPad scene request did not create independent connected scene scopes")
            peerController.apply(title: "Independent", body: "Peer edits while first waits")
            await peerController.waitForOperations()
            peerController.bodyEditor.becomeFirstResponder()
            try require((await peerSession.read()).applicationCount == 1, "Independent scene could not edit during pending acceptance")
        }
        await session.resumeDelivery(); await controller.waitForOperations()
        try require((await session.read()).note == Note(title: "Delayed", body: "Pending effect"), "Delayed group did not finish atomically")
        observations.append("Delayed acceptance refuses repeated native semantic input while preserving UITextView focus and selection.")
        if let peer {
            try require(peer.controller?.bodyEditor.isFirstResponder == true, "First scope completion stole focus from the independent scene")
            try await activate(first, app: app)
            observations.append("Actual iPad scene activation created two connected UIWindowScenes with distinct durable scopes; peer edits/focus survived first-scene pending acceptance and background closure.")
        } else {
            observations.append("Runtime reports multiple scenes unavailable on this iPhone; actual iPad multi-scene check runs on iPad separately.")
        }
        controller.bodyEditor.becomeFirstResponder()
        guard let activeSession = first.session else { throw CheckFailure.observation("Original scene did not return") }

        let beforeLifecycle = await activeSession.read().applicationCount
        await activeSession.delayNextDelivery()
        controller.apply(title: "Lifecycle", body: "Accepted during closure")
        let lifecycleDeadline = Date().addingTimeInterval(10)
        while !(await activeSession.isDeliveryDelayed()) && Date() < lifecycleDeadline {
            try await Task.sleep(for: .milliseconds(40))
        }
        try require(await activeSession.isDeliveryDelayed(), "Lifecycle delayed delivery did not start")
        first.setProtectedDataAvailable(false)
        try await waitUntil("Protected-data closure did not start") { first.state == .closing }
        first.backgroundExpired()
        try require(first.state == .blocked && first.session != nil && controller.view.isHidden,
            "Expired closure released the pending owner or exposed protected content")
        do {
            let duplicate = try await NotesSession.openExisting(at: first.directory)
            try await duplicate.close()
            throw CheckFailure.observation("Pending expired owner allowed a second writer")
        } catch let failure as HistoryFailure {
            try require(failure.cause == .busy, "Pending owner refusal had unexpected cause: \(failure)")
        }
        await activeSession.resumeDelivery()
        try require(await first.close(reason: "injected lifecycle completion"), "Pending lifecycle closure failed")
        first.setProtectedDataAvailable(true); await first.openIfAvailable()
        guard let lifecycleSession = first.session else { throw CheckFailure.observation("Lifecycle gate did not restore") }
        try require((await lifecycleSession.read()).applicationCount == beforeLifecycle + 1,
            "Protected-data/expired closure duplicated or lost the accepted effect")
        observations.append("Injected protected-data and background-expiry policy during delayed delivery hides content and retains the writer until outcome drain; reopening retains exactly one accepted effect. This is not physical lock or OS expiry evidence.")

        #if DEBUG
        let beforeFailure = await lifecycleSession.read().applicationCount
        controller.apply(title: "Recovered", body: "Accepted once", injectFailure: true)
        await controller.waitForOperations()
        try require(controller.router.routingState == .suspended, "Finalization failure did not suspend native history")
        let receiptBytes = try Data(contentsOf: first.directory.appendingPathComponent("Note.json"))
        try require(await first.close(reason: "recovery check"), "Recovery close failed")
        await first.openIfAvailable()
        guard let recovered = first.session else { throw CheckFailure.observation("Recovery reopen failed") }
        try require((await recovered.read()).applicationCount == beforeFailure + 1, "Recovery duplicated the host effect")
        try require(try Data(contentsOf: first.directory.appendingPathComponent("Note.json")) == receiptBytes,
            "Reopen changed authoritative receipt bytes")
        try require(controller.router.canUndo, "Recovery did not rebuild native availability")
        observations.append("Production Debug finalization failure follows durable acceptance; graceful reopening reconciles unchanged receipts without repeating effects.")
        #endif
        guard let current = first.session else { throw CheckFailure.observation("Missing active session") }
        let identity = current.engine.snapshot.scope
        let beforeReopen = await current.read()
        try require(await first.close(reason: "reopen check"), "Native close failed")
        await first.openIfAvailable()
        guard let reopened = first.session else { throw CheckFailure.observation("Native reopen failed") }
        let reopenedReadout = await reopened.read()
        try require(reopened.engine.snapshot.scope == identity && reopenedReadout.applicationCount == beforeReopen.applicationCount,
            "Native reopen changed identity or duplicated an effect")

        await first.setStorageAvailable(false)
        let displaced = first.directory.appendingPathExtension("unavailable")
        try FileManager.default.moveItem(at: first.directory, to: displaced)
        await first.setStorageAvailable(true)
        try require(first.state == .blocked && first.session == nil && !FileManager.default.fileExists(atPath: first.directory.path),
            "Unavailable storage was replaced by a new scope")
        try FileManager.default.moveItem(at: displaced, to: first.directory)
        await first.openIfAvailable()
        try require(first.session?.engine.snapshot.scope == identity, "Returning storage changed the scene scope")
        observations.append("Actual document-directory unavailability refuses restoration without replacement; returning original files restores the same scope.")

        let attributes = try FileManager.default.attributesOfItem(atPath: first.directory.appendingPathComponent("Note.json").path)
        let protection = attributes[.protectionKey].map { String(describing: $0) } ?? "unreported by simulator"
        #if !targetEnvironment(simulator)
        try require(attributes[.protectionKey] as? String == FileProtectionType.complete.rawValue,
            "Physical host state lacks complete file protection: \(protection)")
        #endif
        first.setProtectedDataAvailable(false)
        _ = await first.close(reason: "simulated protected-data gate")
        await first.openIfAvailable()
        try require(first.session == nil && controller.view.isHidden, "Protected-data gate reopened or exposed note content")
        first.setProtectedDataAvailable(true); await first.openIfAvailable()
        try require(first.session?.engine.snapshot.scope == identity && !controller.view.isHidden, "Protected-data gate did not restore original scope")
        observations.append("Complete file protection requested; runtime attribute observation: \(protection). Injected protected-data gate closes/hides content and restores the same scope; no physical lock proof follows.")

        guard let foregroundSession = first.session else { throw CheckFailure.observation("Missing foreground scope") }
        let beforeBackground = await foregroundSession.read()
        let backgroundCount = first.events.filter { $0 == "UIKit scene entered background" }.count
        let stage: [String: String] = ["phase": "background", "scene": first.id,
            "priorBackgroundClosures": String(first.events.filter { $0 == "Outcome drained and store closed: background" }.count)]
        try JSONEncoder().encode(stage).write(to: app.root.appendingPathComponent("Stage.json"), options: .atomic)
        try await waitUntil("Actual UIKit background callback was not observed", timeout: 90) {
            first.events.filter { $0 == "UIKit scene entered background" }.count > backgroundCount
        }
        try await waitUntil("Application did not return to foreground", timeout: 90) { UIApplication.shared.applicationState == .active }
        if first.state != .active || first.scene?.activationState != .foregroundActive { try await activate(first, app: app) }
        try await waitUntil("Foreground did not restore the existing document") { first.state == .active && first.session != nil }
        let afterBackground = await first.session!.read()
        try require(first.session?.engine.snapshot.scope == identity && afterBackground.applicationCount == beforeBackground.applicationCount,
            "Real background/foreground changed scope identity or duplicated an effect")
        try require(first.events.contains("Outcome drained and store closed: background"), "Background did not complete graceful closure")
        observations.append("Runner activated Settings then returned to the app: actual UIKit background/foreground callbacks drained/closed and restored the same scope without another host effect.")

        for owner in Array(app.owners.values) { try require(await owner.close(reason: "native check complete"), "Check closure did not complete") }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let report = Report(runtime: UIDevice.current.systemVersion, model: UIDevice.current.model, architecture: architecture,
            installedRuntime: runtime[0], installedResources: resources.path,
            sceneIDs: app.owners.keys.sorted(), observations: observations,
            events: app.owners.mapValues(\.events), fileProtectionObservation: protection,
            limitations: ["Selected current simulator; no floor OS, Intel, physical lock/device or abrupt-termination qualification.",
                "Programmatic native controls and responder actions; human keyboard/IME observations remain separate."])
        try JSONEncoder().encode(report).write(to: app.root.appendingPathComponent("Report.json"), options: .atomic)
        exit(EXIT_SUCCESS)
    }
}
