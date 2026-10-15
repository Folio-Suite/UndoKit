// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor private final class OpeningRecoveryHost: HistoryHost {
    let host: CounterHost
    private var lookup: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var entered = false

    init(_ host: CounterHost) { self.host = host }

    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        await host.deliver(delivery)
    }

    func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        entered = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { lookup = $0 }
        return await host.outcome(for: token)
    }

    func waitForLookup() async {
        if !entered { await withCheckedContinuation { observer = $0 } }
    }

    func resumeLookup() {
        lookup?.resume()
        lookup = nil
    }
}

@MainActor final class HistoryOpeningActivityTests: XCTestCase {
    func testCloseDuringOpeningPreservesRecoveryAndWriterOwnership() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let scope = UUID(), working = UUID()
        let host = try CounterHost(url: directory.appendingPathComponent("Host.json"))
        let original = try await HistoryEngine.open(at: url, scope: scope,
            workingIdentity: working, mode: .create, host: host)
        host.loseReplyAfterSave = true
        guard case .failure = await original.submit(HistoryCommand(
            fingerprint: Data("set seven".utf8), payload: payload(7))) else {
            return XCTFail("The lost reply must leave recovery work")
        }
        try await original.close()

        let store = try await HistoryStore.open(at: url, workingIdentity: working, mode: .existing)
        let recovery = OpeningRecoveryHost(host)
        let opening = Task { try await store.openScope(scope, mode: .existing, host: recovery) }
        await recovery.waitForLookup()
        var closeStarted = false
        var closeFinished = false
        let closing = Task {
            closeStarted = true
            try await store.close()
            closeFinished = true
        }
        while !closeStarted { await Task.yield() }
        XCTAssertFalse(closeFinished, "Close must wait for opening's authoritative outcome lookup")
        do {
            let competitor = try await HistoryStore.open(at: url, workingIdentity: working, mode: .existing)
            try await competitor.close()
            XCTFail("Opening recovery lost exclusive writer ownership")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .busy)
        }
        recovery.resumeLookup()
        try await closing.value
        let closedEngine = try await opening.value
        XCTAssertFalse(closedEngine.snapshot.canUndo, "A completed open cannot revive the closed scope")

        let reopened = try await HistoryEngine.open(at: url, scope: scope,
            workingIdentity: working, mode: .existing, host: host)
        XCTAssertTrue(reopened.snapshot.canUndo)
        XCTAssertEqual(try reopened.historyPage(limit: 10).count, 1)
        XCTAssertEqual(host.value, 7)
        XCTAssertEqual(host.deliveries, 1, "Recovery must not apply the accepted effect again")
        try await reopened.close()
    }
}
