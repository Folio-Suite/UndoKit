// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import DurableNotesCore
import Foundation
import XCTest

@MainActor final class NotesSessionTests: XCTestCase {
    func testGroupedEditUndoRedoAndReopenRetainDomainAndReceipts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var session = try await NotesSession.open(at: root)
        guard case .accepted = await session.edit(title: "Shopping", body: "Tea and bread") else {
            return XCTFail("Grouped edit was not accepted")
        }
        let edited = await session.read()
        XCTAssertEqual(edited.note, Note(title: "Shopping", body: "Tea and bread"))
        XCTAssertEqual(edited.applicationCount, 1)
        XCTAssertEqual(try session.engine.historyPage(limit: 10).map(\.memberCount), [2])
        guard case .accepted = await session.undo() else { return XCTFail("Undo failed") }
        let undone = await session.read()
        XCTAssertEqual(undone.note, Note())
        guard case .accepted = await session.redo() else { return XCTFail("Redo failed") }
        try await session.close()
        session = try await NotesSession.open(at: root)
        let reopened = await session.read()
        XCTAssertEqual(reopened.note, Note(title: "Shopping", body: "Tea and bread"))
        XCTAssertEqual(reopened.receiptCount, 3)
        XCTAssertEqual(reopened.applicationCount, 3)
        XCTAssertTrue(session.engine.snapshot.canUndo)
        XCTAssertFalse(session.engine.snapshot.canRedo)
        try await session.close()
    }

    #if DEBUG
    func testAcceptedEffectFailedFinalizationReopensWithoutDuplicateEffect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var session = try await NotesSession.open(at: root)
        let result = await session.demonstrateFinalizationFailure(title: "Recovered", body: "Accepted once")
        guard case .failure(let failure) = result else { return XCTFail("Save injection did not fail") }
        XCTAssertEqual(failure.cause, .storage)
        XCTAssertEqual(failure.stage, .finalization)
        XCTAssertTrue(session.engine.snapshot.isSuspended)
        let accepted = await session.read()
        XCTAssertEqual(accepted.note, Note(title: "Recovered", body: "Accepted once"))
        XCTAssertEqual(accepted.applicationCount, 1)
        XCTAssertEqual(accepted.receiptCount, 1)
        XCTAssertTrue(try session.engine.historyPage(limit: 10).isEmpty)
        let original = try Data(contentsOf: root.appendingPathComponent("Note.json"))
        try await session.close()
        session = try await NotesSession.open(at: root)
        let recovered = await session.read()
        XCTAssertEqual(recovered.note, accepted.note)
        XCTAssertEqual(recovered.applicationCount, 1)
        XCTAssertEqual(recovered.receiptCount, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Note.json")), original)
        XCTAssertFalse(session.engine.snapshot.isSuspended)
        XCTAssertTrue(session.engine.snapshot.canUndo)
        XCTAssertEqual(try session.engine.historyPage(limit: 10).map(\.memberCount), [2])
        guard case .accepted = await session.undo() else { return XCTFail("Recovered group cannot Undo") }
        let undone = await session.read()
        XCTAssertEqual(undone.note, Note())
        try await session.close()
    }
    #endif

    func testRejectionPersistsNoEffectAndOtherScopeRemainsIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await NotesSession.open(at: root.appendingPathComponent("A"))
        let b = try await NotesSession.open(at: root.appendingPathComponent("B"))
        await a.rejectNextDelivery()
        let rejection = await a.edit(title: "Rejected", body: "No partial group")
        XCTAssertEqual(rejection, .rejected)
        let rejected = await a.read()
        XCTAssertEqual(rejected.note, Note())
        XCTAssertEqual(rejected.applicationCount, 0)
        XCTAssertEqual(rejected.receiptCount, 1)
        XCTAssertFalse(a.engine.snapshot.canUndo)
        guard case .accepted = await b.edit(title: "Independent", body: "Other document") else {
            return XCTFail("Independent scope was blocked")
        }
        try await a.close()
        let reopened = try await NotesSession.open(at: a.directory)
        XCTAssertNotEqual(reopened.engine.snapshot.scope, b.engine.snapshot.scope)
        let restored = await reopened.read()
        XCTAssertEqual(restored.note, Note())
        XCTAssertEqual(restored.receiptCount, 1)
        try await reopened.close()
        try await b.close()
    }

    func testMissingHostStateIsRefusedWithoutCreatingReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await NotesSession.open(at: root)
        _ = await session.edit(title: "Original", body: "Preserve history")
        try await session.close()
        let host = root.appendingPathComponent("Note.json")
        let history = root.appendingPathComponent("History.sqlite")
        let original = try Data(contentsOf: history)
        try FileManager.default.removeItem(at: host)
        do {
            let unexpected = try await NotesSession.open(at: root)
            try await unexpected.close()
            XCTFail("Missing authoritative host file was replaced")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.path))
        XCTAssertEqual(try Data(contentsOf: history), original)
    }

    func testDuplicateWriterIsRefusedWithoutChangingAuthoritativeState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try await NotesSession.open(at: root)
        _ = await owner.edit(title: "Owned", body: "Single writer")
        let before = try Data(contentsOf: root.appendingPathComponent("Note.json"))
        do {
            let unexpected = try await NotesSession.open(at: root)
            try await unexpected.close()
            XCTFail("A second writer acquired the document")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Note.json")), before)
        XCTAssertTrue(owner.engine.snapshot.canUndo)
        try await owner.close()
        let nextOwner = try await NotesSession.open(at: root)
        let readout = await nextOwner.read()
        XCTAssertEqual(readout.note, Note(title: "Owned", body: "Single writer"))
        try await nextOwner.close()
    }

    func testExistingOpenRefusesUnavailableStorageWithoutCreatingReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await NotesSession.open(at: root)
        _ = await session.edit(title: "Original", body: "Never replace an unavailable document")
        try await session.close()
        let unavailable = root.appendingPathExtension("unavailable")
        defer { try? FileManager.default.removeItem(at: unavailable) }
        try FileManager.default.moveItem(at: root, to: unavailable)
        do {
            let replacement = try await NotesSession.openExisting(at: root)
            try await replacement.close()
            XCTFail("Unavailable storage was replaced")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.moveItem(at: unavailable, to: root)
        let reopened = try await NotesSession.openExisting(at: root)
        let readout = await reopened.read()
        XCTAssertEqual(readout.note, Note(title: "Original", body: "Never replace an unavailable document"))
        XCTAssertEqual(readout.applicationCount, 1)
        try await reopened.close()
    }
}
