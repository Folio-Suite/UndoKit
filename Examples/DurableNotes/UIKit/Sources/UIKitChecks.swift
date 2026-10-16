// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import UIKit
import DurableNotesCore
import UndoKit
import Darwin
import MachO

/// Installed public binding checks. Actual keyboard assistant interaction is separate evidence.
@MainActor enum UIKitChecks {
    struct Report: Codable {
        let runtime: String
        let model: String
        let installedRuntime: String
        let installedResources: String
        let sceneIDs: [String]
        let fileProtectionObservation: String
        let observations: [String]
        let events: [String: [String]]
        let limitations: [String]
    }
    enum CheckFailure: Error { case observation(String) }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure.observation(message) }
    }
    static func waitUntil(_ message: String, condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            guard Date() < deadline else { throw CheckFailure.observation(message) }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    static func matches(_ lhs: NotesReadout, _ rhs: NotesReadout) -> Bool {
        lhs.note == rhs.note && lhs.applicationCount == rhs.applicationCount && lhs.receiptCount == rhs.receiptCount
    }
    static func pause() async throws { try await Task.sleep(for: .milliseconds(120)) }
    static func activate(_ owner: NotesSceneOwner) async throws {
        guard let sceneSession = UIApplication.shared.openSessions.first(where: { $0.persistentIdentifier == owner.id }) else {
            throw CheckFailure.observation("Persistent scene session lost")
        }
        UIApplication.shared.requestSceneSessionActivation(sceneSession, userActivity: nil, options: nil)
        try await waitUntil("Existing scene failed to reactivate") {
            owner.state == .active && owner.scene?.activationState == .foregroundActive
        }
    }
    static func stage(_ name: String, app: NotesUIKitApp) {
        try? Data(name.utf8).write(to: app.root.appendingPathComponent("CheckStage.txt"), options: .atomic)
    }
    static func run(first: NotesSceneOwner, app: NotesUIKitApp) async throws {
        var observations: [String] = []
        let images = (0..<_dyld_image_count()).compactMap { index -> String? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            let path = String(cString: name)
            return path.hasSuffix("/UndoKit.framework/UndoKit") ? path : nil
        }
        try require(images.count == 1 && images[0].hasPrefix(Bundle.main.bundlePath + "/Frameworks/"), "Installed runtime closure failed")
        let resources = Bundle.main.bundleURL.appendingPathComponent("UndoKit_UndoKit.bundle")
        try require(FileManager.default.fileExists(atPath: resources.appendingPathComponent("History.momd").path)
            && FileManager.default.fileExists(atPath: resources.appendingPathComponent("PrivacyInfo.xcprivacy").path), "Installed resources missing")
        guard let controller = first.controller, var binding = controller.binding, var session = first.session,
              let lease = first.lease else { throw CheckFailure.observation("Missing public binding") }
        stage("initial host read", app: app)
        try require(try await lease.read().note == Note(), "Checks require a fresh independent host")
        stage("first grouped action", app: app)
        _ = await lease.edit(title: "Shopping", body: "Tea and bread", in: session)
        try require(try await lease.read().applicationCount == 1, "Grouped edit did not apply once")
        _ = await binding.undoDocument()
        try require(try await lease.read().note == Note(), "Durable Undo did not reverse both fields")
        _ = await binding.redoDocument()
        try require(try await lease.read().note == Note(title: "Shopping", body: "Tea and bread"), "Durable Redo failed")
        observations.append("Public binding accepts and reverses one two-member group against independent host receipts.")

        stage("live typing", app: app)
        controller.bodyEditor.becomeFirstResponder()
        controller.bodyEditor.selectedRange = NSRange(location: 13, length: 0)
        let beforeTyping = try await lease.read()
        controller.bodyEditor.insertText(" live"); try await pause()
        try require(binding.hasLiveTransaction && controller.bodyEditor.undoManager?.canUndo == true, "Native typing did not offer local Undo")
        controller.bodyEditor.undoManager?.undo(); try await pause()
        try require(controller.bodyEditor.text == "Tea and bread", "Live Undo did not restore baseline")
        try require(try await lease.read().applicationCount == beforeTyping.applicationCount,
            "Live native text Undo crossed durable acceptance; micro-edits must remain local until an explicit transaction boundary")
        try require(binding.hasLiveTransaction && controller.bodyEditor.undoManager?.canRedo == true, "Baseline lost local Redo or implicitly settled")
        controller.bodyEditor.undoManager?.redo(); try await pause()
        try require(controller.bodyEditor.text == "Tea and bread live", "Local Redo failed")
        _ = await binding.commit()
        try require(!binding.hasLiveTransaction && controller.bodyEditor.isFirstResponder, "Acceptance lost focus or retained live work")
        try require(try await lease.read().applicationCount == beforeTyping.applicationCount + 1, "Explicit boundary split the coarse group")
        observations.append("UIKit insertion Undo/Redo stays local, including Redo at baseline; explicit acceptance persists one coarse group with focus intact.")

        stage("active rejection", app: app)
        await lease.rejectNextDelivery()
        controller.bodyEditor.insertText(" rejected"); try await pause()
        let beforeRejected = try await lease.read()
        try require(await binding.commit() == .rejected, "Host rejection missing")
        try require(try await lease.read().applicationCount == beforeRejected.applicationCount, "Rejection produced an effect")
        controller.bodyEditor.undoManager?.undo(); try await pause()
        try require(controller.bodyEditor.text == "Tea and bread live" && controller.bodyEditor.undoManager?.canRedo == true, "Rejection destroyed local Undo/Redo")
        let receipts = try await lease.read().receiptCount
        _ = await binding.commit()
        try require(!binding.hasLiveTransaction && !session.status.requiresDraftDecision, "Explicit no-change did not settle")
        try require(try await lease.read().receiptCount == receipts, "No-change redelivered older rejected intent")
        observations.append("Rejected intent retains usable local callbacks and exact evidence; host-declared no change retires them without redelivery.")

        stage("rejected redo boundary", app: app)
        await lease.rejectNextDelivery()
        controller.bodyEditor.insertText(" redo"); try await pause()
        _ = await binding.commit()
        let beforeRejectedRedo = try await lease.read().applicationCount
        _ = await binding.redoDocument()
        let afterRejectedRedo = try await lease.read()
        try require(!session.status.requiresDraftDecision && !binding.hasLiveTransaction
            && afterRejectedRedo.applicationCount == beforeRejectedRedo + 1 && afterRejectedRedo.note.body.hasSuffix(" redo"),
            "Explicit Redo did not settle active rejected intent once")
        _ = await binding.undoDocument() // Restore the worked baseline for the composition cases.
        stage("marked composition", app: app)
        controller.bodyEditor.setMarkedText(" composition", selectedRange: NSRange(location: 12, length: 0))
        try require(controller.bodyEditor.markedTextRange != nil, "UIKit did not form marked text")
        let beforeMarked = try await lease.read().applicationCount
        _ = await binding.commit()
        let markedCount = try await lease.read().applicationCount
        try require(controller.bodyEditor.markedTextRange != nil && markedCount == beforeMarked, "Composition was forcibly settled")
        controller.bodyEditor.unmarkText(); _ = await binding.commit()
        try require(try await lease.read().note.body == "Tea and bread live composition", "Unmarked text was lost")
        let beforeSwitch = try await lease.read().applicationCount
        controller.bodyEditor.setMarkedText(" switch", selectedRange: NSRange(location: 7, length: 0))
        try require(controller.bodyEditor.markedTextRange != nil, "Switch fixture lost marked text")
        controller.titleEditor.becomeFirstResponder()
        if controller.bodyEditor.markedTextRange != nil {
            try require(try await lease.read().applicationCount == beforeSwitch, "Editor switch forced marked settlement")
            controller.bodyEditor.unmarkText()
            controller.titleEditor.selectedRange = NSRange(location: 0, length: 0)
        }
        try await pause(); await binding.waitForOperations()
        try require(try await lease.read().applicationCount == beforeSwitch + 1 && !binding.hasLiveTransaction,
            "Editor switch did not settle after native composition ended")
        controller.bodyEditor.becomeFirstResponder()
        observations.append("Marked ranges prevent settlement; moving to another bound editor settles exactly once after UIKit ends composition, without framework-forced unmarking.")

        stage("delayed acceptance", app: app)
        await lease.delayNextDelivery()
        let delayed = Task { await lease.edit(title: "Delayed", body: "Pending effect", in: session) }
        let deliveryDeadline = Date().addingTimeInterval(30)
        while !(await lease.isDeliveryDelayed()) {
            guard Date() < deliveryDeadline else { throw CheckFailure.observation("Actual delayed host delivery missing") }
            try await pause()
        }
        try require(session.status.phase == .busy, "Actual delivery gate did not retain busy admission")
        let pendingText = controller.bodyEditor.text
        try require(!binding.textView(controller.bodyEditor, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "blocked"), "Delegate barrier permitted native user editing")
        controller.bodyEditor.undoManager?.undo()
        try require(controller.bodyEditor.text == pendingText && controller.bodyEditor.isFirstResponder, "Pending inverse changed text or focus")
        controller.scratch.becomeFirstResponder(); controller.scratch.insertText("local"); try await pause()
        let beforeScratch = try await lease.read().applicationCount
        binding.undoManager.undo(); try await pause()
        let afterScratch = try await lease.read().applicationCount
        try require(controller.scratch.text.isEmpty && beforeScratch == afterScratch, "Scratch affected document history")
        var peer: NotesSceneOwner?
        if UIApplication.shared.supportsMultipleScenes {
            let oldIDs = Set(app.owners.keys); app.requestNewScene()
            try await waitUntil("Independent scene missing") {
                app.owners.values.contains { !oldIDs.contains($0.id) && $0.state == .active }
            }
            peer = app.owners.values.first { !oldIDs.contains($0.id) && $0.state == .active }
            guard peer?.controller?.binding != nil, let peerLease = peer?.lease else { throw CheckFailure.observation("Peer binding missing") }
            _ = await peerLease.edit(title: "Independent", body: "Peer scope", in: peer!.session!)
            peer?.controller?.bodyEditor.becomeFirstResponder()
            try require(try await peerLease.read().applicationCount == 1, "Peer blocked with first scope")
        }
        await lease.resumeDelivery(); _ = await delayed.value
        try require(try await lease.read().note == Note(title: "Delayed", body: "Pending effect"), "Delayed group failed")
        if let peer {
            try require(peer.controller?.bodyEditor.isFirstResponder == true, "Completion stole peer focus")
            try await activate(first)
            observations.append("Actual independent UIWindowScenes preserve peer edits and focus during delayed first-scope acceptance.")
        }
        controller.bodyEditor.becomeFirstResponder()
        observations.append("Pending admission refuses the public native delegate and inverse routes, preserving focus; scratch remains independent.")

        #if DEBUG
        stage("uncertain finalization", app: app)
        controller.bodyEditor.insertText(" uncertain"); try await pause()
        let beforeFailure = try await lease.read()
        let groupCount = try session.advanced.historyPage(limit: 100).count
        let failure = await lease.demonstrateFinalizationFailure(title: controller.titleEditor.text ?? "", body: controller.bodyEditor.text ?? "", in: session)
        guard case .unresolved(let storage) = failure else { throw CheckFailure.observation("Finalization failure missing") }
        try require(storage.cause == .storage && storage.stage == .finalization, "Unexpected finalization failure")
        let acceptedOnce = try await lease.read()
        try require(acceptedOnce.applicationCount == beforeFailure.applicationCount + 1
            && acceptedOnce.receiptCount == beforeFailure.receiptCount + 1
            && acceptedOnce.deliveryCount == beforeFailure.deliveryCount + 1, "Acceptance was not persisted exactly once")
        try require(!binding.undoManager.canUndo && session.status.phase == .suspended, "Uncertain finalization allowed inverses")
        let receipt = try Data(contentsOf: first.directory.appendingPathComponent("Note.json"))
        let blocked = await session.reconcile()
        guard case .unresolved(let blockedFailure)? = blocked else { throw CheckFailure.observation("Failed writable context was reused") }
        let stillAccepted = try await lease.read()
        try require(blockedFailure.cause == .storage && stillAccepted.deliveryCount == acceptedOnce.deliveryCount,
            "In-place reconciliation redelivered accepted work")
        try require(await first.close(reason: "failed-finalization recovery"), "Failed store could not safely close")
        await first.openIfAvailable()
        guard let replacement = first.session, let replacementBinding = controller.binding else {
            throw CheckFailure.observation("Existing-only recovery did not attach")
        }
        session = replacement; binding = replacementBinding
        let recovered = try await lease.read()
        try require(session.status.phase == .ready && !binding.hasLiveTransaction, "Clean reopening did not reconcile acceptance")
        try require(matches(recovered, acceptedOnce) && recovered.deliveryCount == 0, "Recovery replayed domain delivery")
        let groups = try session.advanced.historyPage(limit: 100)
        try require(groups.count == groupCount + 1 && groups.last?.memberCount == 1, "Recovery lost the accepted group")
        try require(try Data(contentsOf: first.directory.appendingPathComponent("Note.json")) == receipt, "Recovery rewrote host receipt")
        observations.append("Debug failed finalization preserved exact host receipt bytes; clean existing-only reopening finalized the original group with zero new delivery callbacks.")
        #endif

        try await injectedLifecycleChecks(first: first, controller: controller, binding: binding,
            session: session, lease: lease, app: app)
        observations.append("Injected protected-data and budget-expiry policy during actual delayed delivery hides content, blocks editing, retains exclusive ownership, then closes and reopens exactly one accepted effect. This is not physical lock or OS expiry proof.")
        observations.append("Moved document storage refuses existing-only reopening without replacement; restoring the original directory preserves scope, content, and receipt bytes. Protected-data false/true separately closes, hides, and reopens without replay.")
        session = first.session!; binding = controller.binding!
        stage("durable reopen", app: app)
        let beforeClose = try await lease.read()
        _ = await first.close(reason: "check reopen"); await first.openIfAvailable()
        session = first.session!; binding = controller.binding!
        try require(matches(try await lease.read(), beforeClose) && session.status.phase == .ready, "Reopen changed content or receipts")
        let protection = try FileManager.default.attributesOfItem(atPath: first.directory.appendingPathComponent("Note.json").path)
        let protectionObservation = protection[.protectionKey].map { String(describing: $0) } ?? "unreported by simulator"
        #if !targetEnvironment(simulator)
        try require(protection[.protectionKey] as? String == FileProtectionType.complete.rawValue, "Physical lease protection lost")
        #endif
        stage("blocked teardown", app: app)
        try await teardownCheck(scene: first.scene!, root: app.root)
        stage("unknown registration", app: app)
        try await unknownRegistrationCheck(root: app.root)
        stage("restored rejection", app: app)
        try await restoredRejectionCheck(root: app.root)
        observations.append("Weak presenter/binding/control release while blocked lease and captured draft remain recoverable; repair retires the session.")
        observations.append("Unexpected facade registrations remain retained across disconnect and block admission/close until explicit certification; reopened rejected evidence requires a new explicit decision.")
        let stage: [String: String] = ["phase": "background", "scene": first.id,
            "priorBackgroundClosures": String(first.events.filter { $0 == "Outcome drained and store closed: background" }.count)]
        let beforeBackground = first.events.filter { $0 == "UIKit scene entered background" }.count
        try JSONEncoder().encode(stage).write(to: app.root.appendingPathComponent("Stage.json"), options: .atomic)
        try await waitUntil("Real Settings transition missing") {
            first.events.filter { $0 == "UIKit scene entered background" }.count > beforeBackground
                && first.scene?.activationState == .foregroundActive && first.state == .active
        }
        try require(matches(try await lease.read(), beforeClose), "Lifecycle replay changed host state")
        observations.append("Real Settings background/foreground closes and reopens the same scope without replay.")
        for owner in Array(app.owners.values) {
            try require(await owner.close(reason: "native check completion"), "Native check closure incomplete")
        }
        await app.sessions.closeAll()
        try require(app.sessions.entries.allSatisfy { $0.status.phase == .closed }, "Recovery owner remained unclosed")
        let report = Report(runtime: UIDevice.current.systemVersion, model: UIDevice.current.model,
            installedRuntime: images[0], installedResources: resources.path, sceneIDs: app.owners.keys.sorted(),
            fileProtectionObservation: protectionObservation, observations: observations,
            events: app.owners.mapValues(\.events), limitations: ["Public programmatic UIKit binding seam; software-keyboard assistant observation is separate.",
                "No hardware shortcuts, physical IME/device, device-lock, or forced-termination qualification."])
        try JSONEncoder().encode(report).write(to: app.root.appendingPathComponent("Report.json"), options: .atomic)
        exit(EXIT_SUCCESS)
    }
    static func injectedLifecycleChecks(first: NotesSceneOwner, controller: NotesUIKitController,
        binding: NativeHistoryUIKitBinding, session: HistorySession,
        lease: NotesDocumentLease, app: NotesUIKitApp) async throws {
        stage("injected protected-data and expiry", app: app)
        let beforeDelivery = try await lease.read().applicationCount
        let scope = session.snapshot.scope
        try require(scope != nil, "Lifecycle check lacks an owned scope")
        await lease.delayNextDelivery()
        let delayed = Task { await lease.edit(title: "Lifecycle", body: "Accepted during closure", in: session) }
        let deadline = Date().addingTimeInterval(30)
        while !(await lease.isDeliveryDelayed()) {
            guard Date() < deadline else { throw CheckFailure.observation("Lifecycle delivery gate did not begin") }
            try await pause()
        }
        first.setProtectedDataAvailable(false)
        try await waitUntil("Injected protected-data closure was not requested") {
            first.events.contains("Closure requested: protected data unavailable") && !binding.isAvailable
        }
        first.backgroundExpired()
        try require(controller.view.isHidden && lease.isOpen && session.status.phase != .closed
            && app.sessions.session(for: first.directory) === session && !binding.undoManager.canUndo,
            "Injected expiry released the pending owner, exposed protected content, or enabled inverse input")
        try require(!binding.textView(controller.bodyEditor, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "blocked"),
            "Protected pending state allowed native editing")
        let duplicate = NotesDocumentLease(directory: first.directory)
        do {
            try await duplicate.open(.existing)
            try await duplicate.close()
            throw CheckFailure.observation("Pending protected owner admitted another writer")
        } catch let failure as HistoryFailure {
            try require(failure.cause == .busy, "Unexpected duplicate-writer refusal")
            try await duplicate.close()
        }
        await lease.resumeDelivery(); _ = await delayed.value
        try await waitUntil("Protected-data drain did not complete") { session.status.phase == .closed && !lease.isOpen }
        first.setProtectedDataAvailable(true)
        try await waitUntil("Protected-data restoration did not reopen") { first.session?.status.phase == .ready && !controller.view.isHidden }
        let accepted = try await lease.read()
        try require(accepted.note == Note(title: "Lifecycle", body: "Accepted during closure")
            && accepted.applicationCount == beforeDelivery + 1 && first.session?.snapshot.scope == scope,
            "Injected policy reopening lost identity or replayed the accepted outcome")

        stage("moved storage refusal and return", app: app)
        let evidenceURL = first.directory.appendingPathComponent("Note.json")
        let receiptBytes = try Data(contentsOf: evidenceURL)
        await first.setStorageAvailable(false)
        try require(first.session?.status.phase == .closed && !lease.isOpen, "Storage gate retained an open writer")
        let displaced = first.directory.appendingPathExtension("unavailable")
        try FileManager.default.moveItem(at: first.directory, to: displaced)
        await first.setStorageAvailable(true)
        try require(first.session?.status.phase == .blocked && !FileManager.default.fileExists(atPath: first.directory.path),
            "Unavailable history was replaced by a new document")
        try FileManager.default.moveItem(at: displaced, to: first.directory)
        await first.openIfAvailable()
        try require(first.session?.status.phase == .ready && first.session?.snapshot.scope == scope,
            "Restored original storage did not reopen the retained scope")
        let returned = try await lease.read()
        let returnedBytes = try Data(contentsOf: evidenceURL)
        try require(matches(returned, accepted) && returnedBytes == receiptBytes,
            "Storage return changed accepted content or receipt evidence")

        stage("injected protected-data false and true", app: app)
        first.setProtectedDataAvailable(false)
        try await waitUntil("Protected-data gate did not close") { first.session?.status.phase == .closed && !lease.isOpen }
        await first.openIfAvailable()
        try require(controller.view.isHidden && first.session?.status.phase == .closed && !binding.isAvailable,
            "Protected-data false reopened or exposed protected UI")
        first.setProtectedDataAvailable(true)
        try await waitUntil("Protected-data true did not restore") { first.session?.status.phase == .ready && !controller.view.isHidden }
        try require(matches(try await lease.read(), accepted) && first.session?.snapshot.scope == scope,
            "Protected-data transition changed scope or replayed accepted content")
    }
    static func unknownRegistrationCheck(root: URL) async throws {
        let directory = root.appendingPathComponent("UnknownRegistration")
        let owners = HistorySessions()
        let lease = NotesDocumentLease(directory: directory)
        let session = await lease.openSession(in: owners, mode: .create)
        var presenter: BindingCheckPresenter? = BindingCheckPresenter()
        try await presenter!.attach(session, lease: lease)
        let target = UnknownUndoTarget()
        var marker: NSObject? = NSObject()
        weak let weakMarker = marker
        presenter!.binding!.undoManager.registerUndo(withTarget: target, selector: #selector(UnknownUndoTarget.restore(_:)), object: marker!)
        marker = nil
        try require(weakMarker != nil && session.status.isEditingBlocked, "Facade lost or ignored unknown registration")
        _ = await presenter!.binding!.commit()
        try require(try await lease.read().applicationCount == 0, "Unknown native work allowed semantic acceptance")
        weak let weakPresenter = presenter
        weak let weakControl = presenter?.editor
        presenter?.binding?.disconnect(); presenter = nil
        try require(weakPresenter == nil && weakControl == nil && weakMarker != nil, "Disconnect discarded unknown work or retained known view")
        await session.close()
        try require(session.status.phase != .closed && weakMarker != nil, "Close silently erased unknown work")
        try await session.reconcileNativeRegistrations()
        try require(weakMarker == nil && target.invocations == 0, "Certification executed or retained unknown callbacks")
        await session.close()
        try require(owners.entries.isEmpty, "Certified owner did not retire")
    }
    static func restoredRejectionCheck(root: URL) async throws {
        let directory = root.appendingPathComponent("RestoredRejection")
        let draftDirectory = directory.appendingPathComponent("HistoryDrafts")
        let owners = HistorySessions()
        let firstLease = NotesDocumentLease(directory: directory)
        let first = await firstLease.openSession(in: owners, mode: .create)
        let originalPresenter = BindingCheckPresenter()
        try await originalPresenter.attach(first, lease: firstLease)
        originalPresenter.editor.text = "Rejected"
        originalPresenter.binding!.textViewDidChange(originalPresenter.editor)
        await firstLease.rejectNextDelivery(); _ = await originalPresenter.binding!.commit(); await first.close()
        originalPresenter.binding!.disconnect()
        let evidence = try journalEvidence(at: draftDirectory)
        let lease = NotesDocumentLease(directory: directory)
        let reopened = await lease.openSession(in: owners, mode: .existing)
        let presenter = BindingCheckPresenter(); try await presenter.attach(reopened, lease: lease)
        try require(reopened.status.requiresDraftDecision && presenter.binding?.undoManager.canUndo == false,
            "Restored rejection implicitly authorized live history")
        try require(presenter.binding?.textView(presenter.editor, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "new") == false,
            "Restored rejection allowed a new intent before explicit decision")
        _ = await presenter.binding?.redoDocument()
        try require(try journalEvidence(at: draftDirectory) == evidence, "Attachment or Redo rewrote restored rejected evidence")
        try require(try await lease.read().applicationCount == 0, "Restored Redo implicitly accepted draft intent")
        _ = await presenter.binding?.retryDraft()
        let accepted = try await lease.read()
        try require(accepted.note.body == "Rejected" && accepted.applicationCount == 1 && accepted.receiptCount == 2,
            "Explicit restored retry did not retain rejection and accept exactly once")
        presenter.binding?.disconnect(); await reopened.close()
    }
    static func journalEvidence(at directory: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var evidence: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            evidence[url.path] = try Data(contentsOf: url)
        }
        return evidence
    }
    static func teardownCheck(scene: UIWindowScene, root: URL) async throws {
        let directory = root.appendingPathComponent("Teardown")
        let draftParent = directory.appendingPathComponent("HistoryDrafts")
        let owners = HistorySessions()
        var lease: NotesDocumentLease? = NotesDocumentLease(directory: directory)
        weak let weakLease = lease
        var session: HistorySession? = await lease!.openSession(in: owners, mode: .create)
        weak let weakSession = session
        var presenter: BindingCheckPresenter? = BindingCheckPresenter()
        let window = UIWindow(windowScene: scene); window.rootViewController = presenter
        window.makeKeyAndVisible()
        try await presenter!.attach(session!, lease: lease!)
        weak let weakPresenter = presenter
        weak let weakEditor = presenter?.editor
        weak let weakBinding = presenter?.binding
        if FileManager.default.fileExists(atPath: draftParent.path) { try FileManager.default.removeItem(at: draftParent) }
        try Data("blocked path".utf8).write(to: draftParent)
        presenter?.editor.becomeFirstResponder(); presenter?.editor.insertText("Unsettled")
        try await pause()
        try require(session?.status.phase == .blocked && presenter?.editor.text == "Unsettled", "Fault did not retain captured draft")
        presenter?.binding?.disconnect(); window.endEditing(true); window.rootViewController = nil; window.isHidden = true; presenter = nil
        try await pause()
        try require(weakPresenter == nil && weakEditor == nil && weakBinding == nil, "Blocked recovery retained UIKit presentation graph")
        lease = nil
        try require(weakLease != nil && owners.entries.count == 1, "Blocked owner lost its recovery lease")
        try FileManager.default.removeItem(at: draftParent)
        try FileManager.default.createDirectory(at: draftParent, withIntermediateDirectories: true)
        _ = await session?.discardDraft(); await session?.close(); session = nil
        try require(owners.entries.isEmpty && weakSession == nil && weakLease == nil, "Repaired owner or lease did not retire")
        (scene.delegate as? NotesSceneDelegate)?.window?.makeKeyAndVisible()
    }
}

@MainActor private final class BindingCheckPresenter: UIViewController {
    let editor = NativeHistoryTextView()
    var binding: NativeHistoryUIKitBinding?
    private var attachment: HistoryAttachment?
    override func loadView() { view = UIView(); view.addSubview(editor); editor.frame = CGRect(x: 0, y: 0, width: 300, height: 150) }
    func attach(_ session: HistorySession, lease: NotesDocumentLease) async throws {
        loadViewIfNeeded()
        attachment = try session.attach(owner: self)
        binding = try await attachment!.bindUIKit(editors: [(editor, try lease.field(.body, in: session))])
    }
}

@MainActor private final class UnknownUndoTarget: NSObject {
    var invocations = 0
    @objc func restore(_ object: NSObject) { invocations += 1 }
}
