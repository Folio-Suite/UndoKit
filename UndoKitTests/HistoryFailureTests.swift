// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor private final class UnresolvedFailureHost: HistoryHost {
    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        .failure(HistoryFailure(.hostProtocol, stage: .delivery, disposition: .suspended))
    }

    func outcome(for token: HistoryToken) async -> HistoryHostOutcome { .unresolved }
}

@MainActor final class HistoryFailureTests: XCTestCase {
    func testNonusableHostFailureStaysSuspendedAcrossReopen() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("History.sqlite")
        let scope = UUID()
        let workingID = UUID()
        let host = UnresolvedFailureHost()
        let engine = try await HistoryEngine.open(at: store, scope: scope,
                                                   workingIdentity: workingID, mode: .create, host: host)
        let command = HistoryCommand(fingerprint: Data("unresolved".utf8),
                                     payload: HistoryPayload(family: "test", data: Data("value".utf8)))
        guard case .failure(let failure) = await engine.submit(command) else {
            XCTFail("Nonusable host failure was not returned")
            return
        }
        XCTAssertEqual(failure.disposition, .suspended)
        XCTAssertTrue(engine.snapshot.isSuspended)
        try await engine.close()

        let reopened = try await HistoryEngine.open(at: store, scope: scope,
                                                    workingIdentity: workingID, mode: .existing, host: host)
        XCTAssertTrue(reopened.snapshot.isSuspended)
        try await reopened.close()
    }
}
