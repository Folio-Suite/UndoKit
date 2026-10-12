// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import UndoKit
import XCTest

extension HistoryRetentionTests {
    func testMissingDetailHoldBoundPreventsConsolidation() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let scope = UUID(), workingID = UUID()
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let limits = HistoryLimits(maxUndoGroups: 1)
        let engine = try await HistoryEngine.open(at: url, scope: scope, workingIdentity: workingID,
            mode: .create, host: host, limits: limits)
        let first = try await accepted(engine, 1)
        _ = try await accepted(engine, 2)
        let boundary = try engine.createCheckpoint(name: "Two", state: payload(2))
        _ = try engine.holdDetail(from: first.groupID, through: first.groupID)
        try await engine.close()

        // Corrupt a closed fixture; assertions remain at the public history boundary.
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let connection = try XCTUnwrap(database)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection,
            "UPDATE ZHISTORYHOLDRECORD SET ZUPPERSEQUENCE = NULL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_changes(connection), 1)

        let reopened = try await HistoryEngine.open(at: url, scope: scope, workingIdentity: workingID,
            mode: .existing, host: host, limits: limits)
        XCTAssertThrowsError(try reopened.retentionHolds())
        XCTAssertThrowsError(try reopened.consolidateHistory(through: boundary.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0)))
        XCTAssertEqual(try reopened.historyPage(limit: 20).count, 2)
        try await reopened.close()
    }

}
