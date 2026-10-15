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
        let owners = NativeHistorySessions<NotesDocumentLease>()
        let lease = NotesDocumentLease(directory: directory)
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        var owner: EditorOwner? = EditorOwner()
        weak let weakOwner = owner
        var binding: NativeHistoryAppKitBinding<NotesDocumentLease>? = try session.connectAppKit(owner: owner!, editors: [owner!.editor],
            captureDraft: { NativeDraftCapture(value: Note(body: $0.editor.string)) },
            draftDidChange: { $0.editor.string = $1.body })
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
        XCTAssertNotNil(lease.history, "Blocked closure must retain the complete lease resources")
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

    @MainActor final class RefreshFaultLease: NativeHistoryLease {
        let notes: NotesDocumentLease
        var history: HistoryEngine? { notes.history }
        var failAfterPreparation = false
        var failNextRead = false
        init(directory: URL) { notes = NotesDocumentLease(directory: directory) }
        func open(_ mode: NativeHistoryOpenMode) async throws { try await notes.open(mode) }
        func close() async throws { try await notes.close() }
        func readDraft() async throws -> NativeDraftSnapshot<Note> {
            if failNextRead { failNextRead = false; throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended) }
            return try await notes.readDraft()
        }
        func makeCommand(from base: NativeDraftSnapshot<Note>, to proposed: Note, generation: UUID) async throws -> HistoryCommand? {
            let command = try await notes.makeCommand(from: base, to: proposed, generation: generation)
            if failAfterPreparation, command != nil { failAfterPreparation = false; failNextRead = true }
            return command
        }
    }
    func testFailedAuthoritativeRefreshBlocksNativeInputAndInverseUntilExactRetry() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<RefreshFaultLease>()
        let lease = RefreshFaultLease(directory: directory)
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        let owner = EditorOwner()
        let binding = try session.connectAppKit(owner: owner, editors: [owner.editor],
            captureDraft: { NativeDraftCapture(value: Note(body: $0.editor.string)) },
            draftDidChange: { $0.editor.string = $1.body })
        lease.failAfterPreparation = true
        _ = await binding.applyDraft(Note(body: "Accepted once"))
        XCTAssertEqual(binding.status.phase, .blocked)
        XCTAssertFalse(binding.permitsEditing)
        XCTAssertFalse(owner.editor.shouldChangeText(inRanges: [NSValue(range: NSRange(location: 0, length: 0))], replacementStrings: ["unsafe"]))
        _ = await binding.undoDocument()
        let receipt = try Data(contentsOf: directory.appendingPathComponent("Note.json"))
        let accepted = try await lease.notes.read()
        XCTAssertEqual(accepted.note.body, "Accepted once")
        XCTAssertEqual(accepted.applicationCount, 1)
        _ = await binding.retryDraft()
        XCTAssertTrue(binding.permitsEditing)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Note.json")), receipt)
        let recovered = try await lease.notes.read()
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
        let owners = NativeHistorySessions<NotesDocumentLease>()
        let lease = NotesDocumentLease(directory: directory)
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        var owner: EditorOwner? = EditorOwner()
        weak let weakOwner = owner
        var binding: NativeHistoryAppKitBinding<NotesDocumentLease>? = try session.connectAppKit(owner: owner!, editors: [owner!.editor],
            captureDraft: { NativeDraftCapture(value: Note(body: $0.editor.string)) },
            draftDidChange: { $0.editor.string = $1.body })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = owner!.editor; window.makeFirstResponder(owner!.editor)
        owner!.editor.insertText("Retained exact draft", replacementRange: NSRange(location: 0, length: 0))
        await binding!.close()
        XCTAssertEqual(session.status.phase, .closed)
        let original = try Data(contentsOf: directory.appendingPathComponent("Note.json"))
        try FileManager.default.moveItem(at: directory, to: moved)
        await owners.reopen(session)
        XCTAssertEqual(session.status.phase, .blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Existing-only attachment must never replace missing storage")
        binding!.disconnect(); binding = nil; owner = nil
        XCTAssertNil(weakOwner, "Blocked session must not retain its presentation owner")
        XCTAssertTrue(owners.session(for: directory) === session)
        await session.close()
        try FileManager.default.moveItem(at: moved, to: directory)
        let reopenedLease = NotesDocumentLease(directory: directory)
        let reopened = await owners.open(documentURL: directory, mode: .existing, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { reopenedLease }
        XCTAssertTrue(reopened.status.requiresDraftDecision)
        XCTAssertEqual(reopened.draft?.body, "Retained exact draft")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Note.json")), original)
        _ = await reopened.undo()
        XCTAssertTrue(reopened.status.requiresDraftDecision)
        let beforeRetry = try await reopenedLease.read()
        XCTAssertEqual(beforeRetry.applicationCount, 0)
        _ = await reopened.retryDraft()
        let afterRetry = try await reopenedLease.read()
        XCTAssertEqual(afterRetry.note.body, "Retained exact draft")
        XCTAssertEqual(afterRetry.applicationCount, 1)
        await reopened.close()
    }

}
