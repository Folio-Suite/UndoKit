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
        let directory = parent.appendingPathComponent("Document")
        let owners = HistorySessions()
        let lease = NotesDocumentLease(directory: directory)
        let first = await lease.openSession(in: owners, mode: .create)
        let second = await lease.openSession(in: owners, mode: .existing)
        XCTAssertTrue(first === second)
        XCTAssertEqual(second.status.phase, .ready)
        await owners.closeAll()
    }
    func testSessionOwnsTypedGroupedEditingAndExclusiveDomainLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let lease = NotesDocumentLease(directory: directory)
        let session = await lease.openSession(in: owners, mode: .create)
        XCTAssertEqual(session.status.phase, .ready)
        let commands = try lease.commands(in: session)
        guard case .accepted = await commands.submitGroup([
            NoteChange(field: .title, expected: "", replacement: "Shopping"),
            NoteChange(field: .body, expected: "", replacement: "Tea and bread")]) else {
            return XCTFail("Typed group was not accepted")
        }
        XCTAssertEqual(try session.advanced.historyPage(limit: 10).map(\.memberCount), [2])
        let edited = try await lease.read()
        XCTAssertEqual(edited.note, Note(title: "Shopping", body: "Tea and bread"))
        XCTAssertEqual(edited.applicationCount, 1)
        let otherOwners = HistorySessions()
        let refusedLease = NotesDocumentLease(directory: directory)
        let refused = await refusedLease.openSession(in: otherOwners, mode: .existing)
        XCTAssertEqual(refused.status.phase, .blocked)
        await refused.close()
        guard case .accepted = await session.undo() else { return XCTFail("Undo failed") }
        let undone = try await lease.read()
        XCTAssertEqual(undone.note, Note())
        XCTAssertEqual(undone.applicationCount, 2)
        await session.close()
        let reopenedLease = NotesDocumentLease(directory: directory)
        let reopened = await reopenedLease.openSession(in: owners, mode: .existing)
        XCTAssertFalse(reopened === session)
        XCTAssertTrue(reopened.status.canRedo)
        guard case .accepted = await reopened.redo() else { return XCTFail("Reopened Redo failed") }
        let redone = try await reopenedLease.read()
        XCTAssertEqual(redone.note, Note(title: "Shopping", body: "Tea and bread"))
        XCTAssertEqual(redone.applicationCount, 3)
        let stale = await commands.submit(NoteChange(field: .body, expected: "Tea and bread", replacement: "Stale"))
        guard case .unexecuted = stale else { return XCTFail("Retired handle executed") }
        await reopened.close()
    }
    func testKnownDocumentRegistryRefusesUnavailableOriginalAcrossFreshAppOwners() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Document-A")
        let moved = root.appendingPathComponent("Moved-original")
        let registry = NotesDocumentRegistry(root: root)
        guard case .create = try registry.openMode(for: directory) else { return XCTFail("New document was not selected for creation") }
        let owners = HistorySessions()
        let lease = NotesDocumentLease(directory: directory)
        let session = await lease.openSession(in: owners, mode: .create)
        await session.close()
        let receipt = try Data(contentsOf: directory.appendingPathComponent("Note.json"))
        try FileManager.default.moveItem(at: directory, to: moved)
        let relaunched = NotesDocumentRegistry(root: root)
        guard case .existing = try relaunched.openMode(for: directory) else { return XCTFail("Known document was selected for replacement") }
        let newOwners = HistorySessions()
        let refusedLease = NotesDocumentLease(directory: directory)
        let refused = await refusedLease.openSession(in: newOwners, mode: try relaunched.openMode(for: directory))
        XCTAssertEqual(refused.status.phase, .blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("Note.json")), receipt)
        await refused.close()
        try FileManager.default.moveItem(at: moved, to: directory)
        let restoredLease = NotesDocumentLease(directory: directory)
        let restored = await restoredLease.openSession(in: newOwners, mode: try relaunched.openMode(for: directory))
        XCTAssertEqual(restored.status.phase, .ready)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Note.json")), receipt)
        await restored.close()
    }
}
