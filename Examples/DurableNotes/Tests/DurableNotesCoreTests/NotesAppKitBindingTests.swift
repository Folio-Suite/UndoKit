// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import AppKit
import DurableNotesCore
import UndoKit
import XCTest

@MainActor final class NotesAppKitBindingTests: XCTestCase {
    @MainActor final class EditorOwner {
        let editor = NativeHistoryAppKitTextView()
        init() { editor.isRichText = false; editor.allowsUndo = true }
    }
    func testStandardNativeInputUndoAndBaselineRedoDoNotDeliverDurableEffects() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NotesDocumentLease>()
        let lease = NotesDocumentLease(directory: directory)
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        let owner = EditorOwner()
        let binding = try session.connectAppKit(owner: owner, editors: [owner.editor],
            captureDraft: { NativeDraftCapture(value: Note(body: $0.editor.string)) },
            draftDidChange: { $0.editor.string = $1.body })
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
        let owners = NativeHistorySessions<NotesDocumentLease>()
        let lease = NotesDocumentLease(directory: directory)
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        let owner = EditorOwner()
        let binding = try session.connectAppKit(owner: owner, editors: [owner.editor],
            captureDraft: { NativeDraftCapture(value: Note(body: $0.editor.string)) },
            draftDidChange: { $0.editor.string = $1.body })
        var evidence: NSObject? = NSObject()
        weak let retainedEvidence = evidence
        binding.undoManager.registerUndo(withTarget: owner) { [evidence] _ in
            _ = evidence; XCTFail("Unknown work must never execute")
        }
        evidence = nil
        XCTAssertFalse(binding.permitsEditing)
        XCTAssertEqual(session.status.issue?.cause, .hostProtocol)
        XCTAssertFalse(owner.editor.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "unsafe"))
        binding.disconnect()
        await session.close()
        XCTAssertEqual(session.status.phase, .blocked)
        XCTAssertNotNil(retainedEvidence)
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
        let owners = NativeHistorySessions<NotesDocumentLease>()
        let lease = NotesDocumentLease(directory: directory)
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        let owner = EditorOwner()
        let binding = try session.connectAppKit(owner: owner, editors: [owner.editor],
            captureDraft: { NativeDraftCapture(value: Note(body: $0.editor.string)) },
            draftDidChange: { $0.editor.string = $1.body })
        _ = await binding.applyDraft(Note(body: "Older"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = owner.editor; window.makeFirstResponder(owner.editor)
        let manager = try XCTUnwrap(owner.editor.undoManager)
        manager.groupsByEvent = false; manager.beginUndoGrouping()
        owner.editor.insertText(" draft", replacementRange: NSRange(location: 5, length: 0))
        manager.endUndoGrouping()
        await lease.rejectNextDelivery()
        let result = await binding.undoDocument()
        XCTAssertEqual(result, .rejected)
        let rejected = try await lease.read()
        XCTAssertEqual(rejected.note.body, "Older")
        XCTAssertEqual(rejected.applicationCount, 1)
        XCTAssertEqual(owner.editor.string, "Older draft")
        XCTAssertTrue(manager.canUndo)
        manager.undo(); XCTAssertEqual(owner.editor.string, "Older")
        XCTAssertTrue(manager.canRedo)
        manager.redo(); XCTAssertEqual(owner.editor.string, "Older draft")
        _ = await binding.undoDocument()
        let undone = try await lease.read()
        XCTAssertEqual(undone.note.body, "Older")
        XCTAssertEqual(undone.applicationCount, 3)
        binding.disconnect(); await session.close()
    }

}
