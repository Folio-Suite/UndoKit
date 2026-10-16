// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor extension HistoryRecordingTests {
    func testRecordingOffPositionDeliversTransientGroupsInUndoRedoOrder() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = RecordingCounterHost()
        let engine = try await HistoryEngine.open(
            at: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host)
        func command(_ delta: Int) -> HistoryCommand {
            HistoryCommand(
                fingerprint: Data(UUID().uuidString.utf8),
                payload: HistoryPayload(family: "counter", data: Data(String(delta).utf8)))
        }

        guard case .accepted(let retained) = await engine.submit(command(1)) else {
            XCTFail("retained edit was not accepted")
            return
        }
        try engine.setRecording(.off)
        guard case .accepted(let first) = await engine.submit(command(2)),
              case .accepted(let second) = await engine.submit(command(3)) else {
            XCTFail("Off edits were not accepted")
            return
        }
        XCTAssertNotEqual(retained.groupID, first.groupID)
        XCTAssertNotEqual(first.groupID, second.groupID)
        XCTAssertTrue(engine.snapshot.canUndo)
        XCTAssertFalse(engine.snapshot.canRedo)

        guard case .accepted(let undoLatest) = await engine.undo() else {
            XCTFail("latest Off edit was not undone")
            return
        }
        XCTAssertTrue(engine.snapshot.canUndo)
        XCTAssertTrue(engine.snapshot.canRedo)
        guard case .accepted(let undoEarlier) = await engine.undo() else {
            XCTFail("earlier Off edit was not undone")
            return
        }
        XCTAssertNotEqual(undoLatest.token.command, undoEarlier.token.command)
        XCTAssertFalse(engine.snapshot.canUndo)
        XCTAssertTrue(engine.snapshot.canRedo)
        XCTAssertEqual(host.value, 1)

        guard case .accepted = await engine.redo(),
              case .accepted = await engine.redo() else {
            XCTFail("Off edits were not redone")
            return
        }
        XCTAssertEqual(host.value, 6)
        XCTAssertFalse(engine.snapshot.canRedo)
        XCTAssertEqual(host.deliveredDeltas, [1, 2, 3, -3, -2, 2, 3])
        try await engine.close()
    }
}
