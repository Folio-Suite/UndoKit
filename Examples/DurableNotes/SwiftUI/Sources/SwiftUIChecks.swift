// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Darwin
import SwiftUI
import UIKit
import DurableNotesCore
import UndoKit

@MainActor enum SwiftUIChecks {
    struct Report: Codable {
        let runtime: String
        let model: String
        let sceneID: String
        let documentPath: String
        let observations: [String]
        let finalNote: Note
        let receiptCount: Int
        let applicationCount: Int
        let recoveryOwnerClosed: Bool
        let presentationReleased: Bool
        let weakPresentationReleased: Bool
        let limitations: [String]
    }

    enum Failure: Error { case check(String) }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.check(message) }
    }
    static func pause() async throws { try await Task.sleep(for: .milliseconds(120)) }
    static func waitUntil(_ message: String, condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !(await condition()) {
            guard Date() < deadline else { throw Failure.check(message) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func run(owner: SwiftUINotesOwner) async {
        let fixtureRoot = owner.documentURL.deletingLastPathComponent()
        do {
            guard var session = owner.session, var binding = owner.binding, let lease = owner.lease else {
                throw Failure.check("Stable scene owner did not open its session and presentation")
            }
            var observations: [String] = []
            try require(session.status.phase == .ready && (session.attachmentCount > 0), "Initial presentation is not ready")
            try require(owner.registry.sessions.entries.count == 1, "Initial open created an unexpected second session")
            let originalSession = session
            let originalBinding = binding
            let originalEditor = owner.bodyEditor
            let originalTitleEditor = owner.titleEditor
            let beforeTyping = try await lease.read()

            owner.bodyEditor.becomeFirstResponder()
            owner.bodyEditor.insertText("SwiftUI draft")
            try await pause()
            try require(binding.hasLiveTransaction && owner.bodyEditor.undoManager?.canUndo == true,
                "Native editor did not retain a live Undo action")
            owner.bodyEditor.undoManager?.undo()
            try await pause()
            try require(owner.bodyEditor.text.isEmpty && owner.bodyEditor.undoManager?.canRedo == true,
                "Native Undo did not restore baseline with Redo available")
            try require(try await lease.read().applicationCount == beforeTyping.applicationCount,
                "A live native edit delivered a durable command")
            owner.bodyEditor.undoManager?.redo()
            try await pause()
            try require(owner.bodyEditor.text == "SwiftUI draft", "Native Redo at baseline failed")
            observations.append("Native UIKit Undo and Redo at baseline remain local in the SwiftUI host.")

            owner.editorGeneration += 1
            try await pause()
            let afterIdentityReplacement = try await lease.read()
            try require(owner.session === originalSession && owner.binding === originalBinding
                && owner.bodyEditor === originalEditor && owner.titleEditor === originalTitleEditor
                && owner.bodyEditor.window != nil && owner.titleEditor.window != nil
                && (session.attachmentCount > 0) && binding.hasLiveTransaction
                && owner.bodyEditor.undoManager?.canUndo == true
                && afterIdentityReplacement.applicationCount == 0 && afterIdentityReplacement.receiptCount == 0,
                "Same-turn SwiftUI identity replacement failed: \(reconstructionSnapshot(owner: owner, session: session, binding: binding)), titleAttached=\(owner.titleEditor.window != nil), applications=\(afterIdentityReplacement.applicationCount), receipts=\(afterIdentityReplacement.receiptCount)")
            observations.append("Same-turn .id replacement remounts both native editors while preserving the exact editor, binding, session, local callbacks and zero durable deliveries.")

            owner.showEditor = false
            try await pause()
            let afterConditionalRemoval = reconstructionSnapshot(owner: owner, session: session, binding: binding)
            owner.showEditor = true
            try await pause()
            let afterConditionalRemount = reconstructionSnapshot(owner: owner, session: session, binding: binding)
            owner.navigationPath.append("history-detail")
            try await pause()
            let afterNavigationPush = reconstructionSnapshot(owner: owner, session: session, binding: binding)
            if !owner.navigationPath.isEmpty { owner.navigationPath.removeLast() }
            try await pause()
            try require(owner.session === originalSession && owner.binding === originalBinding
                && owner.bodyEditor === originalEditor && owner.titleEditor === originalTitleEditor
                && owner.bodyEditor.window != nil && owner.titleEditor.window != nil
                && (session.attachmentCount > 0) && binding.hasLiveTransaction
                && owner.bodyEditor.undoManager?.canUndo == true,
                "SwiftUI reconstruction failed; removed=\(afterConditionalRemoval); remounted=\(afterConditionalRemount); pushed=\(afterNavigationPush); final=\(reconstructionSnapshot(owner: owner, session: session, binding: binding))")
            try require(owner.registry.sessions.entries.count == 1, "SwiftUI reconstruction created another writer")
            observations.append("Editor presentation reconstruction and a real NavigationStack push/pop preserve the same binding, editor, live history and single session.")

            _ = await binding.commit()
            await binding.waitForOperations()
            let accepted = try await lease.read()
            try require(accepted.note.body == "SwiftUI draft"
                && accepted.applicationCount == beforeTyping.applicationCount + 1,
                "Explicit settlement did not produce one accepted host receipt")
            observations.append("Explicit coarse settlement produced one independently readable host effect.")

            guard let primaryWindow = owner.bodyEditor.window, let scene = primaryWindow.windowScene else {
                throw Failure.check("Mounted editor has no UIWindowScene for overlap checks")
            }
            try await checkOverlappingPresentations(scene: scene)
            try require(owner.bodyEditor.window === primaryWindow && owner.session === originalSession
                && owner.binding === originalBinding,
                "Independent overlap probes changed the original editor or session")
            let afterOverlap = try await lease.read()
            try require(afterOverlap.applicationCount == accepted.applicationCount
                && afterOverlap.receiptCount == accepted.receiptCount,
                "SwiftUI presentation handoff delivered or lost a durable receipt")
            observations.append("Standalone UIKit-hosted SwiftUI roots used one editor at a time; removing a weak waiter preserved deterministic survivor promotion, and an unrelated native parent retained control until released.")

            _ = await binding.undoDocument()
            try require(try await lease.read().note.body.isEmpty, "Durable Undo failed")
            _ = await binding.redoDocument()
            let beforeClose = try await lease.read()
            try require(beforeClose.note.body == "SwiftUI draft", "Durable Redo failed")
            await owner.closeForBackground()
            await owner.open()
            session = owner.session!; binding = owner.binding!
            try require(session !== originalSession && session.status.phase == .ready && session.attachmentCount > 0,
                "Reopen did not establish a replacement session attachment")
            let afterReopen = try await lease.read()
            try require(afterReopen.note == beforeClose.note && afterReopen.receiptCount == beforeClose.receiptCount
                && afterReopen.applicationCount == beforeClose.applicationCount,
                "Reopen changed host content or replayed accepted work")
            observations.append("Durable Undo/Redo and complete close/reopen preserve the original content and receipts without replay.")

            owner.bodyEditor.becomeFirstResponder()
            owner.bodyEditor.selectedRange = NSRange(location: (owner.bodyEditor.text ?? "").utf16.count, length: 0)
            owner.bodyEditor.insertText(" focus")
            try await pause()
            let beforeFocus = try await lease.read()
            owner.titleEditor.becomeFirstResponder()
            await binding.waitForOperations()
            let afterFocus = try await lease.read()
            try require(afterFocus.note.body == "SwiftUI draft focus"
                && afterFocus.applicationCount == beforeFocus.applicationCount + 1
                && !binding.hasLiveTransaction,
                "A genuine in-window editor focus change did not settle the live transaction")
            observations.append("A genuine focus change between visible native editors still settles one coarse transaction.")

            owner.scratchEditor.becomeFirstResponder()
            owner.scratchEditor.insertText("local scratch")
            try await pause()
            let beforeScratchUndo = try await lease.read()
            try require(binding.undoManager.canUndo, "Scratch did not own the focused local Undo route")
            binding.undoManager.undo()
            try await pause()
            let afterScratchUndo = try await lease.read()
            try require(owner.scratchEditor.text.isEmpty
                && afterScratchUndo.receiptCount == beforeScratchUndo.receiptCount,
                "Scratch Undo crossed into durable history")
            observations.append("Focused scratch Undo remains local and takes priority over the document route.")

            owner.bodyEditor.becomeFirstResponder()
            let beforeComposition = try await lease.read()
            owner.bodyEditor.setMarkedText(" composition", selectedRange: NSRange(location: 12, length: 0))
            try require(owner.bodyEditor.markedTextRange != nil, "UIKit did not establish marked composition")
            _ = await binding.commit()
            let duringComposition = try await lease.read()
            try require(owner.bodyEditor.markedTextRange != nil
                && duringComposition.applicationCount == beforeComposition.applicationCount,
                "Marked composition was forced into durable history")
            owner.bodyEditor.unmarkText()
            _ = await binding.commit()
            let afterComposition = try await lease.read()
            try require(afterComposition.note.body == owner.bodyEditor.text
                && afterComposition.applicationCount == beforeComposition.applicationCount + 1,
                "Unmarked composition did not settle as one edit")
            observations.append("Marked composition blocks settlement and remains intact; explicit settlement records it after UIKit ends composition.")

            await lease.rejectNextDelivery()
            owner.bodyEditor.insertText(" rejected")
            try await pause()
            let beforeRejection = try await lease.read()
            let rejected = await binding.commit()
            let afterRejection = try await lease.read()
            try require(rejected == .rejected && afterRejection.note == beforeRejection.note
                && afterRejection.applicationCount == beforeRejection.applicationCount
                && binding.hasLiveTransaction && owner.bodyEditor.undoManager?.canUndo == true,
                "Rejected outcome lost evidence, applied an effect or cleared native callbacks")
            owner.editorGeneration += 1
            try await pause()
            try require(owner.bodyEditor.window != nil && owner.binding === binding
                && binding.hasLiveTransaction, "SwiftUI replacement lost the rejected draft or binding")
            owner.bodyEditor.undoManager?.undo()
            try await pause()
            try require(owner.bodyEditor.text == beforeRejection.note.body
                && owner.bodyEditor.undoManager?.canRedo == true,
                "Rejected draft did not preserve usable native Undo and Redo")
            owner.bodyEditor.undoManager?.redo()
            try await pause()
            observations.append("Host rejection has no semantic effect and leaves the draft plus native Undo/Redo callbacks intact.")

            _ = await binding.discardDraft()
            let afterDiscard = try await lease.read()
            try require(!session.status.requiresDraftDecision && !binding.hasLiveTransaction
                && afterDiscard.note == afterRejection.note && afterDiscard.applicationCount == afterRejection.applicationCount
                && afterDiscard.receiptCount == afterRejection.receiptCount && afterDiscard.deliveryCount == afterRejection.deliveryCount
                && owner.bodyEditor.text == beforeRejection.note.body,
                "Explicit discard changed authoritative state or redelivered rejected intent")
            observations.append("Explicit discard retires the proved-rejected draft without a host callback before an independent semantic request.")
            await lease.delayNextDelivery()
            let delayedValue = Note(title: "Pending", body: owner.bodyEditor.text ?? "")
            var delayedResult: HistorySubmissionResult?
            let delayed = Task { @MainActor in
                let result = await lease.edit(title: delayedValue.title, body: delayedValue.body, in: session)
                delayedResult = result
                return result
            }
            try await waitUntil("Delayed edit neither entered host delivery nor returned a result") {
                await lease.isDeliveryDelayed() || delayedResult != nil
            }
            try require(await lease.isDeliveryDelayed(), "Delayed edit finished before host wait: \(String(describing: delayedResult))")
            owner.editorGeneration += 1
            try await pause()
            try require(owner.bodyEditor.window != nil && owner.binding === binding
                && !binding.permitsEditing
                && !binding.textView(owner.bodyEditor, shouldChangeTextIn: NSRange(location: 0, length: 0),
                    replacementText: "unsafe"),
                "Pending SwiftUI replacement lost ownership or enabled native editing")
            try require(session.status.phase == .busy, "Delayed delivery did not hold admission")
            let textDuringPending = owner.bodyEditor.text
            binding.undoManager.undo()
            try await pause()
            try require(owner.bodyEditor.text == textDuringPending && session.status.phase == .busy,
                "Pending admission allowed a native inverse")
            await lease.resumeDelivery()
            let delayedOutcome = await delayed.value
            guard case .accepted = delayedOutcome else { throw Failure.check("Delayed edit was not accepted: \(delayedOutcome)") }
            let afterPending = try await lease.read()
            try require(afterPending.note == delayedValue, "Delayed accepted outcome did not reach host state")
            observations.append("Pending delivery blocks document inverses until the host outcome is released.")

            #if DEBUG
            owner.bodyEditor.insertText(" uncertain")
            try await pause()
            let beforeUncertain = try await lease.read()
            let groupCount = try session.advanced.historyPage(limit: 100).count
            let uncertain = await lease.demonstrateFinalizationFailure(title: owner.titleEditor.text ?? "", body: owner.bodyEditor.text ?? "", in: session)
            guard case .unresolved(let storage) = uncertain else { throw Failure.check("Injected finalization failure did not occur") }
            try require(storage.cause == .storage && storage.stage == .finalization && session.status.phase == .suspended,
                "Unexpected finalization failure")
            let acceptedOnce = try await lease.read()
            try require(acceptedOnce.applicationCount == beforeUncertain.applicationCount + 1
                && acceptedOnce.receiptCount == beforeUncertain.receiptCount + 1
                && acceptedOnce.deliveryCount == beforeUncertain.deliveryCount + 1, "Acceptance was not persisted exactly once")
            let receipt = try Data(contentsOf: owner.documentURL.appendingPathComponent("Note.json"))
            let blocked = await session.reconcile()
            guard case .unresolved(let blockedFailure)? = blocked else { throw Failure.check("Failed writable context was reused") }
            let stillAccepted = try await lease.read()
            try require(blockedFailure.cause == .storage && stillAccepted.deliveryCount == acceptedOnce.deliveryCount,
                "In-place reconciliation redelivered accepted work")
            await owner.closeForBackground()
            try require(session.status.phase == .closed, "Failed store could not safely close")
            await owner.open()
            guard let replacement = owner.session, let replacementBinding = owner.binding else {
                throw Failure.check("Existing-only recovery did not attach")
            }
            session = replacement; binding = replacementBinding
            let afterRecovery = try await lease.read()
            try require(session.status.phase == .ready && !binding.hasLiveTransaction
                && afterRecovery.note == acceptedOnce.note && afterRecovery.applicationCount == acceptedOnce.applicationCount
                && afterRecovery.receiptCount == acceptedOnce.receiptCount && afterRecovery.deliveryCount == 0,
                "Exact accepted outcome recovery replayed or lost the command")
            let groups = try session.advanced.historyPage(limit: 100)
            try require(groups.count == groupCount + 1 && groups.last?.memberCount == 1, "Recovery lost the accepted group")
            try require(try Data(contentsOf: owner.documentURL.appendingPathComponent("Note.json")) == receipt, "Recovery rewrote host receipt")
            observations.append("Debug failed finalization required clean existing-only reopening, finalized the original group and preserved exact receipt bytes with zero new host delivery callbacks.")
            #endif

            if UIDevice.current.userInterfaceIdiom == .pad {
                let priorIDs = Set(owner.registry.activeScenes.map(\.id))
                let activity = NSUserActivity(activityType: "app.foliosuite.UndoKit.DurableNotesSwiftUI.new")
                UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil) { _ in }
                try await waitUntil("A second independent SwiftUI scene did not open") {
                    owner.registry.activeScenes.contains { !priorIDs.contains($0.id) && $0.session?.status.phase == .ready }
                }
                guard let peer = owner.registry.activeScenes.first(where: { !priorIDs.contains($0.id) }),
                      peer.binding != nil, let peerLease = peer.lease else {
                    throw Failure.check("Second scene did not retain an independent session owner")
                }
                _ = await peerLease.edit(title: "Independent", body: "Peer scope", in: peer.session!)
                let peerReadout = try await peerLease.read()
                let localReadout = try await lease.read()
                try require(peerReadout.applicationCount == 1 && localReadout.note.title == "Pending",
                    "The second iPad scene shared the first scene's host history")
                guard let originalScene = owner.windowScene else {
                    throw Failure.check("Original iPad scene window was not retained")
                }
                var activationFailure: String?
                UIApplication.shared.requestSceneSessionActivation(originalScene.session, userActivity: nil, options: nil) { error in
                    activationFailure = String(describing: error)
                }
                try await waitUntil("Original iPad scene did not reactivate: \(activationFailure ?? "no activation callback")") {
                    originalScene.activationState == .foregroundActive && owner.session?.status.phase == .ready
                }
                try require(activationFailure == nil, "Original iPad scene activation failed: \(activationFailure ?? "unknown error")")
                observations.append("An actual second iPad UIWindowScene opens and edits a separate durable scope.")
            } else {
                observations.append("Actual second-window isolation is checked on iPad; this run used an iPhone runtime.")
            }

            let beforeProtection = try await lease.read()
            owner.protectedDataChanged(false)
            try require(!owner.protectedDataAvailable, "Protected-data transition did not hide the document")
            await owner.closeForBackground()
            try require(session.status.phase == .closed, "Protected-data closure did not fully close the store")
            owner.protectedDataChanged(true)
            await owner.open()
            session = owner.session!; binding = owner.binding!
            try require(session.status.phase == .ready && (session.attachmentCount > 0),
                "Protected-data recovery failed to reopen the same retained session")
            let afterProtection = try await lease.read()
            try require(afterProtection.note == beforeProtection.note
                && afterProtection.receiptCount == beforeProtection.receiptCount
                && afterProtection.applicationCount == beforeProtection.applicationCount,
                "Protected-data restoration replaced original content or replayed accepted work")
            observations.append("Injected protected-data unavailability hides the editor, drains and closes, then reopens the original receipt set.")

            await owner.closeForBackground()
            let movedDirectory = owner.documentURL.deletingLastPathComponent()
                .appendingPathComponent("Preserved-\(owner.id)", isDirectory: true)
            let originalHostData = try Data(contentsOf: owner.documentURL.appendingPathComponent("Note.json"))
            try FileManager.default.moveItem(at: owner.documentURL, to: movedDirectory)
            await owner.open()
            let preservedHostData = try Data(contentsOf: movedDirectory.appendingPathComponent("Note.json"))
            session = owner.session!
            try require(session.status.phase != .ready
                && !FileManager.default.fileExists(atPath: owner.documentURL.path)
                && preservedHostData == originalHostData,
                "Unavailable original storage was replaced or its original host data changed")
            try FileManager.default.moveItem(at: movedDirectory, to: owner.documentURL)
            await owner.open()
            session = owner.session!; binding = owner.binding!
            try require(session.status.phase == .ready, "Returning original storage did not recover the same owner")
            observations.append("Existing-only reopen refuses unavailable original storage and preserves the exact host file; restoring it recovers the same owner.")

            let stage = ["phase": "background", "sceneID": owner.id]
            try JSONEncoder().encode(stage).write(to: fixtureRoot.appendingPathComponent("Stage.json"), options: .atomic)
            try await waitUntil("Actual scene background/foreground lifecycle did not close and reopen the owner") {
                FileManager.default.fileExists(atPath: fixtureRoot.appendingPathComponent("ForegroundReady.json").path)
                    && owner.session?.status.phase == .ready
            }
            let backgroundClosedURL = fixtureRoot.appendingPathComponent("BackgroundClosed.json")
            try require(FileManager.default.fileExists(atPath: backgroundClosedURL.path),
                "Scene did not record completed background closure")
            try FileManager.default.removeItem(at: fixtureRoot.appendingPathComponent("Stage.json"))
            try FileManager.default.removeItem(at: backgroundClosedURL)
            try FileManager.default.removeItem(at: fixtureRoot.appendingPathComponent("ForegroundReady.json"))
            observations.append("A real iOS scene background/foreground transition closes and reopens the same history owner without replay.")

            let lifetimeProbe = try await releaseTransientPresentation(registry: owner.registry, scene: owner.windowScene,
                                                                        restoringFocusTo: owner.bodyEditor)
            do {
                try await waitUntil("Transient SwiftUI presentation remained retained") { lifetimeProbe.isReleased }
            } catch {
                throw Failure.check("Transient presentation release failed: \(lifetimeProbe.diagnostic)")
            }
            try require(lifetimeProbe.session?.status.phase == .blocked && lifetimeProbe.lease?.isOpen == true
                && owner.registry.sessions.session(for: lifetimeProbe.documentURL) === lifetimeProbe.session,
                "Blocked presentation release lost its exact retained session or lease: \(lifetimeProbe.diagnostic)")
            try await repairAndClose(lifetimeProbe, registry: owner.registry)
            try await waitUntil("Repaired session or domain lease remained retained: \(lifetimeProbe.diagnostic)") {
                lifetimeProbe.session == nil && lifetimeProbe.lease == nil
            }
            observations.append("A real journal-path obstruction blocks closure while the application collection retains the exact session and lease independently of released SwiftUI presentation objects; repairing only that obstruction permits complete closure.")
            let recovered = SwiftUINotesOwner(id: lifetimeProbe.id, registry: owner.registry)
            await recovered.open()
            guard let recoveredBinding = recovered.binding, let recoveredLease = recovered.lease,
                  let recoveredSession = recovered.session else {
                throw Failure.check("Detached presentation's original document could not reopen")
            }
            try require(recoveredSession.status.requiresDraftDecision
                && recovered.bodyEditor.text == "Unsettled release"
                && recoveredBinding.undoManager.canUndo == false,
                "Reopened unsettled native draft was not decision-gated")
            _ = await recoveredBinding.retryDraft()
            let recoveredReadout = try await recoveredLease.read()
            try require(recoveredReadout.note.body == "Unsettled release" && recoveredReadout.applicationCount == 1,
                "Explicit recovery did not accept the preserved draft exactly once")
            await recovered.closeForBackground()
            recovered.disconnectPresentation()
            observations.append("A mounted SwiftUI presentation releases its owner, editor, binding and hosting controller by weak-reference observation; its unsettled journal reopens decision-gated and retries once.")

            let finalReadout = try await lease.read()
            let sceneOwners = owner.registry.activeScenes
            for scene in sceneOwners {
                await scene.closeForBackground()
                scene.disconnectPresentation()
            }
            await owner.registry.sessions.closeAll()
            let allClosed = owner.registry.sessions.entries.allSatisfy { $0.status.phase == .closed }
            let released = sceneOwners.allSatisfy { ($0.session?.attachmentCount ?? 0) == 0 }
            try require(allClosed && released, "Recovery owners or SwiftUI presentations remain connected after final closure")

            let report = Report(runtime: UIDevice.current.systemVersion, model: UIDevice.current.model,
                sceneID: owner.id, documentPath: owner.documentURL.path, observations: observations,
                finalNote: finalReadout.note, receiptCount: finalReadout.receiptCount,
                applicationCount: finalReadout.applicationCount, recoveryOwnerClosed: allClosed,
                presentationReleased: released, weakPresentationReleased: lifetimeProbe.isReleased,
                limitations: ["No hardware keyboard, physical IME, device-lock or forced-termination qualification."])
            try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            try JSONEncoder().encode(report).write(to: fixtureRoot.appendingPathComponent("Report.json"), options: .atomic)
            exit(EXIT_SUCCESS)
        } catch {
            try? FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            try? Data(String(describing: error).utf8).write(to: fixtureRoot.appendingPathComponent("Failure.txt"), options: .atomic)
            await owner.registry.sessions.closeAll()
            exit(EXIT_FAILURE)
        }
    }

    @MainActor private final class PresentationLifetimeProbe {
        let id: String
        let documentURL: URL
        weak var session: HistorySession?
        weak var lease: NotesDocumentLease?
        weak var owner: SwiftUINotesOwner?
        weak var editor: UITextView?
        weak var binding: NativeHistoryUIKitBinding?
        weak var hostingController: UIViewController?
        weak var nativeContainer: UIView?
        weak var hostingView: UIView?
        weak var window: UIWindow?
        init(id: String, documentURL: URL) { self.id = id; self.documentURL = documentURL }
        var diagnostic: String {
            let superview = editor?.superview.map { String(describing: type(of: $0)) } ?? "nil"
            return "owner=\(owner != nil), editor=\(editor != nil), binding=\(binding != nil), hosting=\(hostingController != nil), superview=\(superview), nativeContainer=\(nativeContainer != nil), hostView=\(hostingView != nil), window=\(window != nil), focused=\(editor?.isFirstResponder == true), attached=\(editor?.window != nil), session=\(session != nil), phase=\(String(describing: session?.status.phase)), lease=\(lease != nil)"
        }
        var isReleased: Bool { owner == nil && editor == nil && binding == nil && hostingController == nil }
    }

    private static func repairAndClose(_ probe: PresentationLifetimeProbe, registry: SwiftUINotesRegistry) async throws {
        guard let retainedSession = probe.session, let retainedLease = probe.lease,
              let configuration = retainedSession.configuration else {
            throw Failure.check("Blocked recovery owner disappeared before repair: \(probe.diagnostic)")
        }
        try FileManager.default.removeItem(at: configuration.journalDirectory)
        await retainedSession.close()
        try require(retainedSession.status.phase == .closed && !retainedLease.isOpen
            && registry.sessions.session(for: probe.documentURL) == nil,
            "Repaired owner did not close its resources: phase=\(retainedSession.status.phase), domainOpen=\(retainedLease.isOpen), \(probe.diagnostic)")
    }

    private static func releaseTransientPresentation(registry: SwiftUINotesRegistry,
                                                     scene: UIWindowScene?,
                                                     restoringFocusTo originalEditor: UITextView) async throws -> PresentationLifetimeProbe {
        guard let scene else { throw Failure.check("No window scene for presentation release observation") }
        let originalWindow = scene.windows.first(where: \.isKeyWindow)
        let id = "Lifetime-\(UUID().uuidString)"
        let transient = SwiftUINotesOwner(id: id, registry: registry)
        let probe = PresentationLifetimeProbe(id: id, documentURL: transient.documentURL)
        await transient.open()
        guard let binding = transient.binding, transient.session?.status.phase == .ready else {
            throw Failure.check("Transient presentation did not acquire its independent document")
        }
        let hosting = UIHostingController(rootView: SwiftUIReleaseProbeView(owner: transient))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        try await pause()
        let obstruction = transient.session!.configuration!.journalDirectory
        if FileManager.default.fileExists(atPath: obstruction.path) { try FileManager.default.removeItem(at: obstruction) }
        try Data("blocked journal directory".utf8).write(to: obstruction)
        transient.bodyEditor.becomeFirstResponder()
        transient.bodyEditor.insertText("Unsettled release")
        try await pause()
        try require(binding.hasLiveTransaction && transient.session?.status.phase == .blocked
            && transient.bodyEditor.text == "Unsettled release",
            "Journal obstruction did not retain the exact native draft in its blocked session")
        probe.session = transient.session; probe.lease = transient.lease
        probe.owner = transient; probe.editor = transient.bodyEditor
        probe.nativeContainer = transient.bodyEditor.superview
        probe.hostingView = hosting.view; probe.window = window
        probe.binding = binding; probe.hostingController = hosting
        transient.disconnectPresentation()
        window.endEditing(true)
        await transient.closeForBackground()
        try require(transient.session?.status.phase == .blocked && transient.lease?.isOpen == true,
            "Blocked journal closure discarded the original lease")
        window.isHidden = true
        window.rootViewController = nil
        originalWindow?.makeKeyAndVisible()
        originalEditor.becomeFirstResponder()
        UIAccessibility.post(notification: .layoutChanged, argument: originalEditor)
        return probe
    }

    /// Form rows may remain cached after disappearance. Dispose standalone hosting
    /// roots here so this probe exercises actual representable dismantling.
    private static func checkOverlappingPresentations(scene: UIWindowScene) async throws {
        let editor = NativeHistoryTextView()
        func window() -> UIWindow {
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: SwiftUIOverlappingEditorProbe(editor: editor))
            window.isHidden = false
            window.layoutIfNeeded()
            return window
        }
        let first = window()
        try await waitUntil("Initial standalone SwiftUI editor did not mount") { editor.window === first }
        let removed = window()
        try await pause()
        let second = window()
        try await pause()
        let third = window()
        defer {
            for window in [first, removed, second, third] {
                window.rootViewController = nil
                window.isHidden = true
            }
        }
        try await pause()
        try require(editor.window === first, "An overlapping SwiftUI host stole the current editor")
        // Repeated updates keep the same representable identity and must not duplicate its waiter.
        if let hosting = second.rootViewController as? UIHostingController<SwiftUIOverlappingEditorProbe> {
            hosting.rootView = SwiftUIOverlappingEditorProbe(editor: editor)
            hosting.view.layoutIfNeeded()
        }
        weak let removedHosting = removed.rootViewController
        removed.rootViewController = nil
        removed.isHidden = true
        try await waitUntil("Waiting SwiftUI host was retained after removal") { removedHosting == nil }
        first.rootViewController = nil
        first.isHidden = true
        try await waitUntil("First surviving SwiftUI waiter did not receive editor") { editor.window === second }
        second.rootViewController = nil
        second.isHidden = true
        try await waitUntil("Surviving SwiftUI waiters lost attachment order") { editor.window === third }
        third.rootViewController = nil
        third.isHidden = true
        try await waitUntil("Last SwiftUI host did not release editor") { editor.superview == nil }

        let externalWindow = UIWindow(windowScene: scene)
        let externalController = UIViewController()
        externalWindow.rootViewController = externalController
        externalWindow.isHidden = false
        let externalParent = externalController.view!
        externalParent.addSubview(editor)
        let attemptedSteal = window()
        defer {
            attemptedSteal.rootViewController = nil
            attemptedSteal.isHidden = true
            editor.removeFromSuperview()
            externalWindow.rootViewController = nil
            externalWindow.isHidden = true
        }
        try await pause()
        try require(editor.superview === externalParent,
            "SwiftUI reparented an editor already owned by an unrelated native view")
        attemptedSteal.rootViewController = nil
        attemptedSteal.isHidden = true
        editor.removeFromSuperview()
        let remounted = window()
        defer { remounted.rootViewController = nil; remounted.isHidden = true }
        try await waitUntil("Editor did not remount after its unrelated parent released it") { editor.window === remounted }
    }

    private static func reconstructionSnapshot(owner: SwiftUINotesOwner, session: HistorySession,
                                                binding: NativeHistoryUIKitBinding) -> String {
        "phase=\(session.status.phase), connection=\((session.attachmentCount > 0)), live=\(binding.hasLiveTransaction), undo=\(owner.bodyEditor.undoManager?.canUndo == true), attached=\(owner.bodyEditor.window != nil), detail=\(!owner.navigationPath.isEmpty)"
    }
}

@MainActor private struct SwiftUIReleaseProbeView: View {
    @ObservedObject var owner: SwiftUINotesOwner
    var body: some View {
        NativeHistorySwiftUIEditor(textView: owner.bodyEditor)
            .padding()
    }
}

@MainActor private struct SwiftUIOverlappingEditorProbe: View {
    let editor: NativeHistoryTextView
    var body: some View {
        NativeHistorySwiftUIEditor(textView: editor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
