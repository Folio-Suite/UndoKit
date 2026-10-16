// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import AppKit
import DurableNotesCore
import UndoKit
import XCTest

@MainActor final class NotesAppKitBindingTests: XCTestCase {
    @MainActor final class EditorOwner {
        let editor = NativeHistoryAppKitTextView()
        var attachment: HistoryAttachment?
        init() { editor.isRichText = false; editor.allowsUndo = true }
    }
    func testStandardNativeInputUndoAndBaselineRedoDoNotDeliverDurableEffects() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let lease = NotesDocumentLease(directory: directory)
        let session = await lease.openSession(in: owners, mode: .create)
        let owner = EditorOwner()
        owner.attachment = try session.attach(owner: owner)
        let binding = try await owner.attachment!.bindAppKit(editors: [(owner.editor, try lease.field(.body, in: session))])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = owner.editor
        window.makeFirstResponder(owner.editor)
        let manager = try XCTUnwrap(owner.editor.undoManager)
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        owner.editor.insertText("Alpha", replacementRange: NSRange(location: 0, length: 0))
        manager.endUndoGrouping()
        XCTAssertEqual(owner.editor.string, "Alpha")
        XCTAssertTrue(binding.hasLiveTransaction)
        XCTAssertEqual(binding.status.phase, .ready)
        XCTAssertTrue(manager.canUndo)
        let undoItem = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        XCTAssertTrue(owner.editor.responds(to: undoItem.action!), "The bound editor must own the standard Undo responder action")
        XCTAssertTrue(owner.editor.validateUserInterfaceItem(undoItem), "Native menu validation must expose live Undo")
        manager.undo()
        XCTAssertEqual(owner.editor.string, "")
        XCTAssertTrue(manager.canRedo, "Redo must remain native after returning to baseline")
        manager.redo()
        XCTAssertEqual(owner.editor.string, "Alpha")
        let readout = try await lease.read()
        XCTAssertEqual(readout.applicationCount, 0)
        XCTAssertEqual(readout.receiptCount, 0)
        binding.disconnect(); await session.close()
    }
    func testUnknownCallbacksRemainRetainedThroughDisconnectAndBlockedClosureUntilReconciled() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let lease = NotesDocumentLease(directory: directory)
        let session = await lease.openSession(in: owners, mode: .create)
        var owner: EditorOwner? = EditorOwner()
        weak let weakOwner = owner
        owner!.attachment = try session.attach(owner: owner!)
        var binding: NativeHistoryAppKitBinding? = try await owner!.attachment!.bindAppKit(editors: [(owner!.editor, try lease.field(.body, in: session))])
        weak let weakBinding = binding
        var evidence: NSObject? = NSObject()
        weak let retainedEvidence = evidence
        binding!.undoManager.registerUndo(withTarget: evidence!) { [evidence] _ in
            _ = evidence; XCTFail("Unknown work must never execute")
        }
        evidence = nil
        XCTAssertFalse(binding!.permitsEditing)
        XCTAssertEqual(session.status.issue?.cause, .hostProtocol)
        XCTAssertFalse(owner!.editor.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "unsafe"))
        binding!.disconnect(); binding = nil; owner = nil
        XCTAssertNil(weakOwner)
        XCTAssertNil(weakBinding)
        await session.close()
        XCTAssertEqual(session.status.phase, .blocked)
        XCTAssertNotNil(retainedEvidence)
        let retained = try await lease.read()
        XCTAssertEqual(retained.applicationCount, 0, "Blocked closure must retain domain resources")
        XCTAssertTrue(owners.session(for: directory) === session)
        try await session.reconcileNativeRegistrations()
        XCTAssertNil(retainedEvidence)
        await session.close()
        XCTAssertEqual(session.status.phase, .closed)
    }

    func testRejectedLiveDraftDoesNotUndoAnOlderGroupAndKeepsNativeHistory() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let lease = NotesDocumentLease(directory: directory)
        let session = await lease.openSession(in: owners, mode: .create)
        let owner = EditorOwner()
        owner.attachment = try session.attach(owner: owner)
        let binding = try await owner.attachment!.bindAppKit(editors: [(owner.editor, try lease.field(.body, in: session))])
        _ = await lease.edit(title: "", body: "Older", in: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = owner.editor; window.makeFirstResponder(owner.editor)
        let manager = try XCTUnwrap(owner.editor.undoManager)
        manager.groupsByEvent = false; manager.beginUndoGrouping()
        owner.editor.insertText(" draft", replacementRange: NSRange(location: 5, length: 0))
        manager.endUndoGrouping()
        await lease.rejectNextDelivery()
        let result = await binding.undoDocument()
        guard case .unexecuted(let failure) = result else { return XCTFail("Dependent Undo was delivered: \(result)") }
        XCTAssertEqual(failure.cause, .prerequisiteRejected)
        let rejected = try await lease.read()
        XCTAssertEqual(rejected.note.body, "Older")
        XCTAssertEqual(rejected.applicationCount, 1)
        XCTAssertEqual(owner.editor.string, "Older draft")
        XCTAssertTrue(manager.canUndo)
        manager.undo(); XCTAssertEqual(owner.editor.string, "Older")
        XCTAssertTrue(manager.canRedo)
        manager.redo(); XCTAssertEqual(owner.editor.string, "Older draft")
        let retried = await binding.undoDocument()
        guard case .accepted = retried else { return XCTFail("Explicit live retry did not settle and undo: \(retried)") }
        let undone = try await lease.read()
        XCTAssertEqual(undone.note.body, "Older")
        XCTAssertEqual(undone.applicationCount, 3)
        binding.disconnect(); await session.close()
    }

    @MainActor final class ReadFault {
        var failNext = false
        var failAfterPreparation = false
    }
    func testFailedAuthoritativeRefreshBlocksNativeInputAndInverseUntilExactRetry() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let lease = NotesDocumentLease(directory: directory)
        let session = await lease.openSession(in: owners, mode: .create)
        let fault = ReadFault()
        let field = HistoryField(id: "body", mappingID: "fault-body.v1", codec: HistoryCodec<String>.json(),
            commands: try lease.commands(in: session), read: {
                if fault.failNext { fault.failNext = false; throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended) }
                let readout = try await lease.read()
                return HistoryFieldSnapshot(value: readout.note.body, revision: Data(String(readout.applicationCount).utf8))
            }, makeCommands: { base, proposed in
                if fault.failAfterPreparation { fault.failAfterPreparation = false; fault.failNext = true }
                return [NoteChange(field: .body, expected: base.value, replacement: proposed)]
            })
        let owner = EditorOwner()
        owner.attachment = try session.attach(owner: owner)
        let binding = try await owner.attachment!.bindAppKit(editors: [(owner.editor, field)])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = owner.editor; window.makeFirstResponder(owner.editor)
        fault.failAfterPreparation = true
        owner.editor.insertText("Accepted once", replacementRange: NSRange(location: 0, length: 0))
        _ = await binding.commit()
        XCTAssertEqual(binding.status.phase, .blocked)
        XCTAssertFalse(binding.permitsEditing)
        XCTAssertFalse(owner.editor.shouldChangeText(inRanges: [NSValue(range: NSRange(location: 0, length: 0))], replacementStrings: ["unsafe"]))
        _ = await binding.undoDocument()
        let receipt = try Data(contentsOf: directory.appendingPathComponent("Note.json"))
        let accepted = try await lease.read()
        XCTAssertEqual(accepted.note.body, "Accepted once")
        XCTAssertEqual(accepted.applicationCount, 1)
        _ = await binding.retryDraft()
        XCTAssertTrue(binding.permitsEditing)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Note.json")), receipt)
        let recovered = try await lease.read()
        XCTAssertEqual(recovered.applicationCount, 1)
        binding.disconnect(); await session.close()
    }
    func testUnavailableStorageRefusesReplacementAndReopenedRetainedDraftNeedsDecision() async throws {
        _ = NSApplication.shared
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("Note")
        let moved = parent.appendingPathComponent("Unavailable")
        let owners = HistorySessions()
        let lease = NotesDocumentLease(directory: directory)
        let session = await lease.openSession(in: owners, mode: .create)
        var owner: EditorOwner? = EditorOwner()
        weak let weakOwner = owner
        owner!.attachment = try session.attach(owner: owner!)
        var binding: NativeHistoryAppKitBinding? = try await owner!.attachment!.bindAppKit(editors: [(owner!.editor, try lease.field(.body, in: session))])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = owner!.editor; window.makeFirstResponder(owner!.editor)
        owner!.editor.insertText("Retained exact draft", replacementRange: NSRange(location: 0, length: 0))
        await binding!.close()
        XCTAssertEqual(session.status.phase, .closed)
        let original = try Data(contentsOf: directory.appendingPathComponent("Note.json"))
        try FileManager.default.moveItem(at: directory, to: moved)
        binding!.disconnect(); binding = nil; owner = nil
        XCTAssertNil(weakOwner)
        let refusedLease = NotesDocumentLease(directory: directory)
        let refused = await refusedLease.openSession(in: owners, mode: .existing)
        XCTAssertEqual(refused.status.phase, .blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Existing-only attachment must never replace missing storage")
        await refused.close()
        try FileManager.default.moveItem(at: moved, to: directory)
        let reopenedLease = NotesDocumentLease(directory: directory)
        let reopened = await reopenedLease.openSession(in: owners, mode: .existing)
        let restoredOwner = EditorOwner()
        restoredOwner.attachment = try reopened.attach(owner: restoredOwner)
        let restoredBinding = try await restoredOwner.attachment!.bindAppKit(editors: [
            (restoredOwner.editor, try reopenedLease.field(.body, in: reopened))])
        XCTAssertTrue(reopened.status.requiresDraftDecision)
        XCTAssertEqual(restoredOwner.editor.string, "Retained exact draft")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Note.json")), original)
        _ = await reopened.undo()
        XCTAssertTrue(reopened.status.requiresDraftDecision)
        let beforeRetry = try await reopenedLease.read()
        XCTAssertEqual(beforeRetry.applicationCount, 0)
        _ = await restoredBinding.retryDraft()
        let afterRetry = try await reopenedLease.read()
        XCTAssertEqual(afterRetry.note.body, "Retained exact draft")
        XCTAssertEqual(afterRetry.applicationCount, 1)
        restoredBinding.disconnect(); await reopened.close()
    }

}
