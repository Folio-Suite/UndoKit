// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor final class HistoryTransactionInterfaceTests: XCTestCase {
    func testProtocolSubmitsUndoesRedoesAndWorksAfterReopen() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("History.sqlite")
        let hostURL = directory.appendingPathComponent("host.json")
        let scope = UUID()
        let workingIdentity = UUID()

        let firstHost = try CounterHost(url: hostURL)
        let firstEngine = try await HistoryEngine.open(
            at: store, scope: scope, workingIdentity: workingIdentity,
            mode: .create, host: firstHost)
        let first: any HistoryTransactions = firstEngine
        var callbackSnapshots: [HistorySnapshot] = []
        first.snapshotDidChange = { callbackSnapshots.append($0) }

        guard case .accepted = await first.submit(HistoryCommand(
            fingerprint: Data("set 7".utf8), payload: payload(7),
            expectedGeneration: first.snapshot.generation)) else {
            XCTFail("Protocol submission was not accepted")
            return
        }
        XCTAssertEqual(firstHost.value, 7)
        XCTAssertTrue(first.snapshot.canUndo)
        XCTAssertFalse(callbackSnapshots.isEmpty)
        guard case .accepted = await first.undo(expectedGeneration: first.snapshot.generation) else {
            XCTFail("Protocol undo was not accepted")
            return
        }
        XCTAssertEqual(firstHost.value, 0)
        guard case .accepted = await first.redo(expectedGeneration: first.snapshot.generation) else {
            XCTFail("Protocol redo was not accepted")
            return
        }
        XCTAssertEqual(firstHost.value, 7)
        try await firstEngine.close()

        let reopenedHost = try CounterHost(url: hostURL)
        let reopenedEngine = try await HistoryEngine.open(
            at: store, scope: scope, workingIdentity: workingIdentity,
            mode: .existing, host: reopenedHost)
        let reopened: any HistoryTransactions = reopenedEngine
        XCTAssertEqual(reopenedHost.value, 7)
        guard case .accepted = await reopened.undo(expectedGeneration: reopened.snapshot.generation) else {
            XCTFail("Protocol action after reopen was not accepted")
            return
        }
        XCTAssertEqual(reopenedHost.value, 0)
        try await reopenedEngine.close()
    }
}
