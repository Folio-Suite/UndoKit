// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

extension HistoryRecordingTests {
    func testRejectedOffUndoBlocksOlderGroupsWithoutReleasingRequiredObjects() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = RecordingCounterHost()
        let resource = HistoryObjectReference(storeID: UUID(), objectKey: "off-effect")
        host.requiredResource = resource
        let store = try await HistoryStore.open(
            at: directory.appendingPathComponent("History.sqlite"),
            workingIdentity: UUID(), mode: .create)
        let engine = try await store.openScope(UUID(), mode: .create, host: host)
        try engine.setRecording(.off)
        for delta in [1, 2] {
            let result = await engine.submit(
                HistoryCommand(
                    fingerprint: Data(String(delta).utf8),
                    payload: HistoryPayload(family: "counter", data: Data(String(delta).utf8))))
            guard case .accepted = result else {
                XCTFail("Off edit was not accepted")
                return
            }
        }
        host.rejectNext = true
        let rejected = await engine.undo()
        XCTAssertEqual(rejected, .rejected)
        XCTAssertFalse(engine.snapshot.canUndo)
        XCTAssertFalse(engine.snapshot.canRedo)
        let deliveries = host.deliveries
        let repeated = await engine.undo()
        XCTAssertEqual(repeated, .rejected)
        XCTAssertEqual(host.deliveries, deliveries)
        XCTAssertEqual(host.value, 3)
        XCTAssertTrue(try engine.historyPage(limit: 10).isEmpty)
        XCTAssertEqual(
            try store.requiredObjects(in: resource.storeID, limit: 10)
                .objects.map(\.reference), [resource])
        try await store.close()
    }

    func testRejectedOffRedoKeepsBarrierAcrossNewCommandsAndUndoDepthEviction() async throws {
        for startsRetained in [false, true] {
            let directory = try testDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let host = RecordingCounterHost()
            let engine = try await HistoryEngine.open(
                at: directory.appendingPathComponent("History.sqlite"),
                scope: UUID(), workingIdentity: UUID(), mode: .create, host: host,
                limits: HistoryLimits(maxPayloadBytes: 128, maxUndoGroups: 4))
            if !startsRetained { try engine.setRecording(.off) }
            for delta in [1, 2] {
                let result = await engine.submit(recordingCommand(delta))
                guard case .accepted = result else {
                    XCTFail("Initial edit was not accepted")
                    return
                }
            }
            if startsRetained { try engine.setRecording(.off) }
            guard case .accepted = await engine.undo() else {
                XCTFail("Undo was not accepted")
                return
            }
            host.rejectNext = true
            let rejected = await engine.redo()
            XCTAssertEqual(rejected, .rejected)
            XCTAssertFalse(engine.snapshot.canUndo)
            XCTAssertFalse(engine.snapshot.canRedo)
            await assertRejectedTraversalDoesNotDeliver(engine, host: host)

            for _ in 0..<5 {
                let result = await engine.submit(recordingCommand(1))
                guard case .accepted = result else {
                    XCTFail("Independent edit was not accepted")
                    return
                }
            }
            XCTAssertEqual(host.value, 6)
            XCTAssertFalse(engine.snapshot.canUndo)
            XCTAssertFalse(engine.snapshot.canRedo)
            let afterNewCommands = host.deliveries
            let blockedUndo = await engine.undo()
            let blockedRedo = await engine.redo()
            XCTAssertEqual(blockedUndo, .rejected)
            XCTAssertEqual(blockedRedo, .rejected)
            XCTAssertEqual(host.deliveries, afterNewCommands)
            XCTAssertEqual(try engine.historyPage(limit: 10).count, startsRetained ? 2 : 0)
            try await engine.close()
        }
    }

    func testRejectedRetainedUndoPreservesHistoryAndBarrierOnReopen() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let scope = UUID()
        let workingID = UUID()
        let host = RecordingCounterHost()
        let engine = try await HistoryEngine.open(
            at: url, scope: scope,
            workingIdentity: workingID, mode: .create, host: host)
        for delta in [1, 2] {
            let result = await engine.submit(recordingCommand(delta))
            guard case .accepted = result else {
                XCTFail("Retained edit was not accepted")
                return
            }
        }
        host.rejectNext = true
        let rejected = await engine.undo()
        XCTAssertEqual(rejected, .rejected)
        XCTAssertFalse(engine.snapshot.canUndo)
        XCTAssertFalse(engine.snapshot.canRedo)
        try await engine.close()
        let reopened = try await HistoryEngine.open(
            at: url, scope: scope,
            workingIdentity: workingID, mode: .existing, host: host)
        let deliveries = host.deliveries
        let repeated = await reopened.undo()
        XCTAssertEqual(repeated, .rejected)
        XCTAssertEqual(host.deliveries, deliveries)
        XCTAssertEqual(host.value, 3)
        XCTAssertFalse(reopened.snapshot.canUndo)
        XCTAssertFalse(reopened.snapshot.canRedo)
        XCTAssertEqual(try reopened.historyPage(limit: 10).count, 2)
        try await reopened.close()
    }

    private func assertRejectedTraversalDoesNotDeliver(_ engine: HistoryEngine, host: RecordingCounterHost) async {
        let deliveries = host.deliveries
        let repeated = await engine.redo()
        let olderUndo = await engine.undo()
        XCTAssertEqual(repeated, .rejected)
        XCTAssertEqual(olderUndo, .rejected)
        XCTAssertEqual(host.deliveries, deliveries)
        XCTAssertEqual(host.value, 1)
    }

    private func recordingCommand(_ delta: Int) -> HistoryCommand {
        HistoryCommand(
            fingerprint: Data(UUID().uuidString.utf8),
            payload: HistoryPayload(family: "counter", data: Data(String(delta).utf8)))
    }

}
