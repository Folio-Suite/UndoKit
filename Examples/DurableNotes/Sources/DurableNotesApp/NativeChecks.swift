// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import AppKit
import Darwin
import DurableNotesCore
import UndoKit

/// Installed native controls/responder checks; human keyboard/IME evidence is separate.
@MainActor enum NativeChecks {
    struct Report: Codable {
        let runtime: String
        let architecture: String
        let loadedUndoKit: String
        let observations: [String]
        let limits: [String]
    }
    enum CheckFailure: Error { case observation(String) }
    private static func require(_ value: Bool, _ description: String) throws {
        guard value else { throw CheckFailure.observation(description) }
    }
    private static func focus(_ controller: NotesWindowController, editor: NSTextView) {
        controller.window?.makeKeyAndOrderFront(nil); controller.window?.makeFirstResponder(editor)
    }
    private static func command(_ action: String) -> Bool {
        NSApp.sendAction(NSSelectorFromString(action), to: nil, from: NSApp.mainMenu)
    }
    private static func pump() async { try? await Task.sleep(for: .milliseconds(40)) }
    private static func insert(_ value: String, in editor: NSTextView) {
        let manager = editor.undoManager!
        manager.groupsByEvent = false; manager.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(value, replacementRange: editor.selectedRange())
        manager.endUndoGrouping()
    }

    static func run(a: NotesWindowController, b: NotesWindowController, root: URL) async throws {
        var observations: [String] = []
        let loaded = (0..<_dyld_image_count()).compactMap { index -> String? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            let path = String(cString: name)
            return path.hasSuffix("/libUndoKit.dylib") ? URL(fileURLWithPath: path).standardizedFileURL.path : nil
        }
        try require(loaded.count == 1 && loaded[0].hasPrefix(Bundle.main.privateFrameworksPath ?? "<missing>"),
            "Expected exactly one installed UndoKit runtime")
        try require(try await a.read().note == Note(), "Fresh fixture required")
        focus(a, editor: a.bodyEditor); await pump()
        insert("Alpha", in: a.bodyEditor)
        try require(command("undo:"), "Responder Undo absent")
        try require(a.bodyEditor.string.isEmpty && a.bodyEditor.undoManager!.canRedo, "Native baseline Redo absent")
        try require(command("redo:"), "Responder Redo absent")
        try require(a.bodyEditor.string == "Alpha", "Native Redo lost text")
        let live = try await a.read()
        try require(live.applicationCount == 0 && live.receiptCount == 0, "Live input delivered durable effects")
        let selectedText = NSRange(location: 1, length: 3)
        a.bodyEditor.setSelectedRange(selectedText)
        _ = await a.binding.commit()
        try require(a.bodyEditor.selectedRange() == selectedText, "Committing unchanged text moved the native selection")
        let committed = try await a.read()
        try require(committed.note.body == "Alpha" && committed.applicationCount == 1 && committed.receiptCount == 1,
            "Explicit boundary did not persist one group")
        _ = command("undo:"); await a.waitForOperations()
        try require(try await a.read().note == Note(), "Durable responder Undo failed")
        _ = command("redo:"); await a.waitForOperations()
        try require(try await a.read().note.body == "Alpha", "Durable responder Redo failed")
        observations.append("Focused standard NSTextView insert/live Undo/baseline Redo produced zero host applications/receipts; explicit commit produced exactly one; responder Undo/Redo then used durable history.")

        a.apply(title: "Shopping", body: "Tea and bread"); await a.waitForOperations()
        let grouped = try a.session.advanced.historyPage(limit: 20).last
        try require(grouped?.memberCount == 2, "Host grouped fields did not persist as one two-member group")
        focus(a, editor: a.titleEditor); await pump(); _ = command("undo:"); await a.waitForOperations()
        try require(try await a.read().note == Note(body: "Alpha"), "Grouped Undo was partial")
        _ = command("redo:"); await a.waitForOperations()
        observations.append("A host action changing two Note fields persisted one two-member Undo Group, reversed/reapplied through the AppKit responder chain.")

        focus(a, editor: a.bodyEditor); await pump()
        insert(" live", in: a.bodyEditor)
        await a.lease.rejectNextDelivery()
        let beforeRejection = try await a.read()
        let rejected = await a.binding.undoDocument()
        guard case .unexecuted(let prerequisiteFailure) = rejected else {
            throw CheckFailure.observation("Dependent Undo was delivered after rejected native settlement")
        }
        try require(prerequisiteFailure.cause == .prerequisiteRejected, "Rejected prerequisite was not identified")
        try require(try await a.read().applicationCount == beforeRejection.applicationCount, "Rejected draft fell through to older group")
        try require(a.bodyEditor.string == "Tea and bread live" && a.bodyEditor.undoManager!.canUndo, "Rejected draft lost native history")
        _ = command("undo:"); _ = command("redo:")
        try require(a.bodyEditor.string == "Tea and bread live", "Rejected baseline native Redo failed")
        _ = await a.binding.discardDraft()
        observations.append("Authoritative rejection on explicit durable Undo retained draft/live Undo/Redo and did not fall through to an older durable group; explicit discard restored authority.")

        focus(a, editor: a.bodyEditor)
        let manager = a.bodyEditor.undoManager!
        manager.beginUndoGrouping()
        a.bodyEditor.setMarkedText(" composition", selectedRange: NSRange(location: 12, length: 0),
            replacementRange: NSRange(location: a.bodyEditor.string.utf16.count, length: 0))
        try require(a.bodyEditor.hasMarkedText(), "Native marked-text input absent")
        let beforeComposition = try await a.read()
        _ = await a.binding.undoDocument()
        try require(try await a.read().applicationCount == beforeComposition.applicationCount, "Composition submitted early")
        try require(!manager.canUndo && a.bodyEditor.hasMarkedText(), "Composition Undo barrier destroyed native marked text")
        try require(!a.binding.settleEditing(), "Marked focus boundary should defer")
        a.bodyEditor.unmarkText(); manager.endUndoGrouping()
        await pump(); await a.binding.waitForOperations()
        try require(try await a.read().note.body == "Tea and bread composition", "Composed text lost")
        observations.append("Real NSTextInputClient marked text blocked live/durable Undo and settlement without forced composition; explicit unmark+commit preserved composed text.")

        focus(a, editor: a.scratch); await pump()
        let beforeLocal = try await a.read()
        _ = command("undo:")
        insert("scratch", in: a.scratch); _ = command("undo:")
        try require(a.scratch.string.isEmpty, "Scratch native Undo failed")
        try require(try await a.read().applicationCount == beforeLocal.applicationCount, "Scratch fell through to durable history")
        observations.append("Local scratch native Undo and empty-history Undo never reached document history.")

        await a.lease.delayNextDelivery()
        a.apply(title: "Delayed", body: "Waits for receipt")
        for _ in 0..<100 { if await a.lease.isDeliveryDelayed() { break }; await pump() }
        try require(await a.lease.isDeliveryDelayed(), "Controlled pending delivery absent")
        try require(!a.binding.permitsEditing && !a.bodyEditor.isEditable, "Pending editing barrier absent")
        try require(!a.bodyEditor.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "unsafe"), "Native input admission failed while pending")
        focus(a, editor: a.bodyEditor); _ = command("undo:"); _ = command("undo:")
        focus(b, editor: b.bodyEditor)
        b.apply(title: "Independent", body: "Other scope remains usable"); await b.waitForOperations()
        let focused = b.window?.firstResponder
        await a.lease.resumeDelivery(); await a.waitForOperations()
        try require(try await a.read().note.title == "Delayed", "Pending repeated Undo changed target")
        try require(try await b.read().applicationCount == 1, "Other scope blocked")
        try require(b.window?.firstResponder === focused && NSApp.keyWindow === b.window, "Async completion stole focus")
        observations.append("Pending host acceptance refused real text admission and repeated Undo, while independent window B edited and retained focus.")

        #if DEBUG
        focus(a, editor: a.bodyEditor)
        a.titleEditor.string = "Recovered"; a.bodyEditor.string = "Accepted once"
        let beforeFailure = try await a.read()
        let groupCount = try a.session.advanced.historyPage(limit: 100).count
        let failed = await a.lease.demonstrateFinalizationFailure(title: a.titleEditor.string, body: a.bodyEditor.string, in: a.session)
        guard case .unresolved(let failure) = failed else { throw CheckFailure.observation("Finalization injection did not suspend") }
        try require(failure.cause == .storage && failure.stage == .finalization, "Unexpected finalization failure")
        try require(!a.binding.permitsEditing, "Failed finalization did not block input")
        let acceptedOnce = try await a.read()
        try require(acceptedOnce.applicationCount == beforeFailure.applicationCount + 1
            && acceptedOnce.receiptCount == beforeFailure.receiptCount + 1
            && acceptedOnce.deliveryCount == beforeFailure.deliveryCount + 1, "Acceptance was not persisted exactly once")
        let receipt = try Data(contentsOf: a.directory.appendingPathComponent("Note.json"))
        let blocked = await a.session.reconcile()
        guard case .unresolved(let blockedFailure)? = blocked else { throw CheckFailure.observation("Failed writable context was reused") }
        try require(blockedFailure.cause == .storage, "Failed context did not require clean reopening")
        try require(try await a.read().deliveryCount == acceptedOnce.deliveryCount, "In-place reconciliation redelivered accepted work")
        try await a.reopenSession()
        let recovered = try await a.read()
        try require(a.session.status.phase == .ready && !a.binding.hasLiveTransaction, "Clean reopening did not reconcile acceptance")
        try require(recovered.note == acceptedOnce.note && recovered.applicationCount == acceptedOnce.applicationCount
            && recovered.receiptCount == acceptedOnce.receiptCount && recovered.deliveryCount == 0, "Recovery replayed domain delivery")
        let groups = try a.session.advanced.historyPage(limit: 100)
        try require(groups.count == groupCount + 1 && groups.last?.memberCount == 2, "Recovery lost the complete accepted group")
        try require(try Data(contentsOf: a.directory.appendingPathComponent("Note.json")) == receipt, "Recovery rewrote host receipt")
        observations.append("Debug accepted-effect/failed-finalization required a clean existing-only reopen, finalized the original two-member group, preserved exact receipt bytes and made zero new host delivery callbacks.")
        #endif
        let persisted = try await a.read()
        let reopenReceipt = try Data(contentsOf: a.directory.appendingPathComponent("Note.json"))
        try await a.reopenSession()
        try require(try await a.read().note == persisted.note && a.binding.undoManager.canUndo, "Reopen lost persisted availability")
        try require(try Data(contentsOf: a.directory.appendingPathComponent("Note.json")) == reopenReceipt, "Reopen replayed domain delivery")
        focus(a, editor: a.bodyEditor); _ = command("undo:"); await a.waitForOperations()
        try await a.reopenSession()
        try require(a.binding.undoManager.canRedo, "Reopen lost durable Redo")
        observations.append("Complete host/history close and existing-only reopen independently read persisted Note/receipts without replay, then rebuilt durable Undo and reopened Redo.")
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let report = Report(runtime: ProcessInfo.processInfo.operatingSystemVersionString, architecture: architecture,
            loadedUndoKit: loaded[0], observations: observations,
            limits: ["Programmatic native input/responder actions; actual keyboard and physical IME review is separate.",
                "Current Mac runtime only; no floor OS, Intel, physical device or forced-termination qualification."])
        try JSONEncoder().encode(report).write(to: root.appendingPathComponent("NativeReport.json"), options: .atomic)
        print("UNDOKIT_NOTES_NATIVE_PASS \(root.path)")
    }
}
