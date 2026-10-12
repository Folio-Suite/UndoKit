// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import AppKit
import Darwin
import DurableNotesCore
import UndoKit

/// Runs inside the actual AppKit app. Method-level host tests remain separate.
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
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(editor)
    }
    private static func command(_ action: String) -> Bool {
        NSApp.sendAction(NSSelectorFromString(action), to: nil, from: NSApp.mainMenu)
    }
    private static func pump() async { try? await Task.sleep(for: .milliseconds(40)) }

    static func run(a: NotesWindowController, b: NotesWindowController, root: URL) async throws {
        var observations: [String] = []
        let loadedUndoKit = (0..<_dyld_image_count()).compactMap { index -> String? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            let path = String(cString: name)
            return path.hasSuffix("/libUndoKit.dylib") ? URL(fileURLWithPath: path).standardizedFileURL.path : nil
        }
        try require(loadedUndoKit.count == 1, "Expected one UndoKit runtime identity")
        try require(loadedUndoKit[0].hasPrefix(Bundle.main.privateFrameworksPath ?? "<missing>"),
            "Native app loaded UndoKit from a build directory instead of its installed Frameworks")
        try require((await a.session.read()).note == Note(), "Native fixture requires a fresh document directory")
        a.apply(title: "Shopping", body: "Tea and bread")
        await a.waitForOperations()
        try require((await a.session.read()).applicationCount == 1, "Grouped edit did not commit once")
        focus(a, editor: a.bodyEditor)
        try require(command("undo:"), "AppKit responder chain did not route Undo")
        await a.waitForOperations()
        try require((await a.session.read()).note == Note(), "Native Undo did not reverse both fields")
        try require(command("redo:"), "AppKit responder chain did not route Redo")
        await a.waitForOperations()
        try require((await a.session.read()).note == Note(title: "Shopping", body: "Tea and bread"), "Native Redo did not reapply group")
        observations.append("Visible AppKit window, focused NSTextView and responder-chain Undo/Redo reversed/reapplied a two-member group.")

        // Explicit native group boundaries make this check repeatable independently
        // of the event-loop's timing. Ordinary interactive typing uses AppKit coalescing.
        let manager = a.router.undoManager
        manager.groupsByEvent = false
        let beforeTyping = await a.session.read().applicationCount
        manager.beginUndoGrouping()
        a.bodyEditor.setSelectedRange(NSRange(location: a.bodyEditor.string.utf16.count, length: 0))
        a.bodyEditor.insertText(" and", replacementRange: a.bodyEditor.selectedRange())
        manager.endUndoGrouping()
        await pump()
        try require((await a.session.read()).applicationCount == beforeTyping,
            "Runloop group closure prematurely submitted coalescing native typing")
        manager.beginUndoGrouping()
        a.bodyEditor.insertText(" milk", replacementRange: a.bodyEditor.selectedRange())
        manager.endUndoGrouping()
        await pump()
        _ = a.settleEditing()
        await a.waitForOperations()
        try require((await a.session.read()).note.body == "Tea and bread and milk", "Native text group did not persist")
        try require(try a.session.engine.historyPage(limit: 20).last?.memberCount == 1, "Typing did not produce one body member")
        try require(command("undo:"), "Typing Undo did not route")
        await a.waitForOperations()
        try require((await a.session.read()).note.body == "Tea and bread", "Typing Undo did not reverse the whole native group")
        observations.append("NSTextView typing across two native event-group closures remained provisional until settlement and persisted as one semantic Undo step.")

        // A real NSTextInputClient composing range must defer semantic settlement.
        manager.beginUndoGrouping()
        a.bodyEditor.setSelectedRange(NSRange(location: a.bodyEditor.string.utf16.count, length: 0))
        a.bodyEditor.setMarkedText(" composition", selectedRange: NSRange(location: 12, length: 0),
            replacementRange: a.bodyEditor.selectedRange())
        try require(a.bodyEditor.hasMarkedText(), "NSTextView did not begin marked text")
        let beforeComposition = await a.session.read()
        _ = command("undo:")
        await pump()
        try require(a.router.pendingInvocationID == nil, "Marked text allowed an asynchronous semantic Undo")
        try require((await a.session.read()).applicationCount == beforeComposition.applicationCount, "Marked text committed early")
        a.bodyEditor.unmarkText()
        manager.endUndoGrouping()
        _ = a.settleEditing()
        await a.waitForOperations()
        try require((await a.session.read()).note.body == "Tea and bread composition", "Settled marked text was lost")
        _ = command("undo:"); await a.waitForOperations()
        observations.append("NSTextView marked text blocked semantic Undo until unmarking and settlement; committed composition was then undoable.")

        focus(a, editor: a.scratch)
        a.scratch.localHistory.removeAllActions()
        let beforeLocal = await a.session.read()
        _ = command("undo:"); await pump()
        try require((await a.session.read()).applicationCount == beforeLocal.applicationCount, "Empty local history fell through to document Undo")
        a.scratch.localHistory.groupsByEvent = false
        a.scratch.localHistory.beginUndoGrouping()
        a.scratch.insertText("scratch", replacementRange: NSRange(location: 0, length: 0))
        a.scratch.localHistory.endUndoGrouping()
        _ = command("undo:"); await pump()
        try require(a.scratch.string.isEmpty, "Local scratch Undo failed")
        try require((await a.session.read()).applicationCount == beforeLocal.applicationCount, "Local scratch mutated durable domain")
        observations.append("Focused local scratch used its own native history, including empty-history Undo, without reaching the document.")

        await a.session.delayNextDelivery()
        a.apply(title: "Delayed", body: "Waits for receipt")
        for _ in 0..<100 {
            if await a.session.isDeliveryDelayed() { break }
            await pump()
        }
        try require(await a.session.isDeliveryDelayed(), "Delivery did not enter controlled pending state")
        try require(a.router.routingState == .pending && !a.bodyEditor.isEditable, "Pending native editing barrier was absent")
        focus(a, editor: a.bodyEditor)
        _ = command("undo:"); _ = command("undo:")
        focus(b, editor: b.bodyEditor)
        b.apply(title: "Independent", body: "Other scope remains usable")
        await b.waitForOperations()
        let focused = b.window?.firstResponder
        await a.session.resumeDelivery(); await a.waitForOperations()
        try require((await a.session.read()).note == Note(title: "Delayed", body: "Waits for receipt"), "Repeated pending Undo changed delayed target")
        try require((await b.session.read()).applicationCount == 1, "Other scope could not edit while A waited")
        try require(b.window?.firstResponder === focused && NSApp.keyWindow === b.window, "Completion stole focus from B")
        try require(a.bodyEditor.isEditable, "Finalized outcome did not lift barrier")
        observations.append("Delayed acceptance blocked repeat semantic input in A while B edited independently; A completion preserved B focus.")

        await a.session.rejectNextDelivery()
        a.apply(title: "Rejected", body: "Never applied")
        await a.waitForOperations()
        try require(a.lastResult == .rejected, "Host rejection did not surface")
        try require((await a.session.read()).note == Note(title: "Delayed", body: "Waits for receipt"), "Rejection partially changed a group")
        try require(a.bodyEditor.isEditable, "Rejection did not lift native barrier")
        observations.append("Authoritative rejection refreshed the native controls without a partial domain effect or a stuck barrier.")

        #if DEBUG
        let applications = await a.session.read().applicationCount
        let failure = await a.session.demonstrateFinalizationFailure(title: "Recovered", body: "Accepted once")
        await a.refresh(result: failure)
        try require(a.router.routingState == .suspended && !a.bodyEditor.isEditable, "Failed finalization did not suspend native editing")
        let bytes = try Data(contentsOf: a.session.directory.appendingPathComponent("Note.json"))
        try await a.reopenSession()
        try require((await a.session.read()).applicationCount == applications + 1, "Reconciliation duplicated host effect")
        try require(try Data(contentsOf: a.session.directory.appendingPathComponent("Note.json")) == bytes, "Reopen rewrote authoritative receipt")
        try require(a.router.canUndo && a.bodyEditor.isEditable, "Reopen did not rebuild native availability")
        focus(a, editor: a.bodyEditor); _ = command("undo:"); await a.waitForOperations()
        try require((await a.session.read()).note == Note(title: "Delayed", body: "Waits for receipt"), "Recovered group did not Undo atomically")
        try await a.reopenSession()
        try require(a.router.canRedo, "Reopen lost committed Redo")
        observations.append("Production Debug finalization failure suspended editing after durable acceptance; graceful reopen reconciled unchanged receipt bytes once and restored Undo/Redo.")
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let report = Report(runtime: ProcessInfo.processInfo.operatingSystemVersionString, architecture: architecture,
            loadedUndoKit: loadedUndoKit[0],
            observations: observations, limits: ["Programmatic native input and responder actions; human keyboard/IME review remains separate.",
                "Selected current Mac only; no floor OS, Intel, iOS, physical-device or abrupt-termination qualification."])
        try JSONEncoder().encode(report).write(to: root.appendingPathComponent("NativeReport.json"), options: .atomic)
        print("UNDOKIT_NOTES_NATIVE_PASS \(root.path)")
    }
}
