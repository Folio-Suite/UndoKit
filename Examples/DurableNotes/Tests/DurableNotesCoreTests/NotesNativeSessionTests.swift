// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import DurableNotesCore
import Foundation
import UndoKit
import XCTest

@MainActor final class NotesNativeSessionTests: XCTestCase {
    func testCreatedDirectoryURLStillReturnsTheSameOwningSession() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let beforeCreation = parent.appendingPathComponent("Document")
        let owners = NativeHistorySessions<NotesDocumentLease>()
        let first = await owners.open(documentURL: beforeCreation, mode: .create, codec: .json(),
            draftURL: beforeCreation.appendingPathComponent("Draft.json")) { NotesDocumentLease(directory: beforeCreation) }
        let afterCreation = parent.appendingPathComponent("Document")
        let second = await owners.open(documentURL: afterCreation, mode: .existing, codec: .json(),
            draftURL: afterCreation.appendingPathComponent("Draft.json")) { NotesDocumentLease(directory: afterCreation) }
        XCTAssertTrue(first === second, "Filesystem creation changed the canonical owner identity")
        XCTAssertEqual(second.status.phase, .ready)
        await owners.closeAll()
    }
    func testExistingLegacyDraftIsRefusedWithoutReplacingOriginalEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NotesDocumentLease>()
        let draftURL = directory.appendingPathComponent("Draft.json")
        let original = await owners.open(documentURL: directory, mode: .create, codec: .json(), draftURL: draftURL) {
            NotesDocumentLease(directory: directory)
        }
        await original.close()
        let evidence = Data(#"{"title":"Unsettled title","body":"Unsettled body"}"#.utf8)
        try evidence.write(to: draftURL)
        let reopened = await owners.open(documentURL: directory, mode: .existing, codec: .json(), draftURL: draftURL) {
            NotesDocumentLease(directory: directory)
        }
        XCTAssertEqual(reopened.status.phase, .blocked)
        _ = await reopened.discardDraft()
        XCTAssertEqual(try Data(contentsOf: draftURL), evidence)
        await reopened.close()
        XCTAssertEqual(try Data(contentsOf: draftURL), evidence)
    }
    func testNativeSessionOwnsGroupedNoteEditingAndExclusiveDocumentLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NotesDocumentLease>()
        let lease = NotesDocumentLease(directory: directory)
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        XCTAssertEqual(session.status.phase, .ready)
        try session.updateDraft(Note(title: "Shopping", body: "Tea and bread"))
        guard case .accepted = await session.commit() else { return XCTFail("Grouped draft was not accepted") }
        let edited = try await lease.read()
        XCTAssertEqual(edited.note, Note(title: "Shopping", body: "Tea and bread"))
        XCTAssertEqual(edited.applicationCount, 1)
        let otherOwners = NativeHistorySessions<NotesDocumentLease>()
        let refused = await otherOwners.open(documentURL: directory, mode: .existing, codec: .json(),
            draftURL: directory.appendingPathComponent("OtherDraft.json")) { NotesDocumentLease(directory: directory) }
        XCTAssertEqual(refused.status.phase, .blocked)
        await refused.close()
        guard case .accepted = await session.undo() else { return XCTFail("Undo failed") }
        let undone = try await lease.read()
        XCTAssertEqual(undone.note, Note())
        XCTAssertEqual(undone.applicationCount, 2)
        await session.close()
        let reopenedLease = NotesDocumentLease(directory: directory)
        let reopened = await owners.open(documentURL: directory, mode: .existing, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { reopenedLease }
        XCTAssertTrue(reopened.status.canRedo)
        guard case .accepted = await reopened.redo() else { return XCTFail("Reopened Redo failed") }
        let redone = try await reopenedLease.read()
        XCTAssertEqual(redone.note, Note(title: "Shopping", body: "Tea and bread"))
        XCTAssertEqual(redone.applicationCount, 3)
        await reopened.close()
    }
}
