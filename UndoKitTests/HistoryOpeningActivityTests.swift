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
    func testCloseWaitsForExplicitReconciliationAndPreservesItsAcceptedReceipt() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("Host.json"))
        let recovery = OpeningRecoveryHost(host)
        let engine = try await HistoryEngine.open(
            at: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: recovery)
        host.loseReplyAfterSave = true
        guard case .failure = await engine.submit(HistoryCommand(fingerprint: Data([9]), payload: payload(9))) else {
            XCTFail("Lost reply must require recovery")
            return
        }
        let reconciling = Task { await engine.reconcile() }
        await recovery.waitForLookup()
        reconciling.cancel()
        var closeStarted = false
        var closeFinished = false
        let closing = Task {
            closeStarted = true
            try await engine.close()
            closeFinished = true
        }
        while !closeStarted { await Task.yield() }
        XCTAssertFalse(closeFinished)
        recovery.resumeLookup()
        guard case .accepted = await reconciling.value else {
            XCTFail("Original receipt must reconcile")
            return
        }
        try await closing.value
        XCTAssertTrue(closeFinished)
        XCTAssertFalse(engine.snapshot.canUndo)
        XCTAssertEqual(host.deliveries, 1)
        XCTAssertEqual(host.value, 9)
    }

    func testCloseDuringOpeningPreservesRecoveryAndWriterOwnership() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let scope = UUID()
        let working = UUID()
        let host = try CounterHost(url: directory.appendingPathComponent("Host.json"))
        let original = try await HistoryEngine.open(
            at: url, scope: scope,
            workingIdentity: working, mode: .create, host: host)
        host.loseReplyAfterSave = true
        guard
            case .failure = await original.submit(
                HistoryCommand(
                    fingerprint: Data("set seven".utf8), payload: payload(7)))
        else {
            XCTFail("The lost reply must leave recovery work")
            return
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
        try await assertWriterIsExclusivelyOwned(at: url, workingIdentity: working)
        recovery.resumeLookup()
        try await closing.value
        let closedEngine = try await opening.value
        XCTAssertFalse(closedEngine.snapshot.canUndo, "A completed open cannot revive the closed scope")

        let reopened = try await HistoryEngine.open(
            at: url, scope: scope,
            workingIdentity: working, mode: .existing, host: host)
        XCTAssertTrue(reopened.snapshot.canUndo)
        XCTAssertEqual(try reopened.historyPage(limit: 10).count, 1)
        XCTAssertEqual(host.value, 7)
        XCTAssertEqual(host.deliveries, 1, "Recovery must not apply the accepted effect again")
        try await reopened.close()
    }
    func testMaintenanceDrainsSuspendedOpeningAndPreservesAuthoritativeOriginal() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let hostURL = directory.appendingPathComponent("Host.json")
        let scope = UUID(), working = UUID()
        let host = try CounterHost(url: hostURL)
        let original = try await HistoryEngine.open(
            at: url, scope: scope, workingIdentity: working, mode: .create, host: host)
        host.loseReplyAfterSave = true
        guard case .failure = await original.submit(HistoryCommand(fingerprint: Data([7]), payload: payload(7))) else {
            XCTFail("Lost reply must require recovery")
            return
        }
        try await original.close()
        let originalHost = try Data(contentsOf: hostURL)
        let store = try await HistoryStore.open(at: url, workingIdentity: working, mode: .existing)
        let recovery = OpeningRecoveryHost(host)
        let opening = Task { try await store.openScope(scope, mode: .existing, host: recovery) }
        await recovery.waitForLookup()
        let started = expectation(description: "Maintenance installed its store fence")
        var captured = false
        let copyURL = directory.appendingPathComponent("Copy.sqlite")
        let copying = Task {
            started.fulfill()
            try await store.withCoordinatedCopy(to: copyURL) { _ in captured = true }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(captured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path))
        do {
            try await store.close()
            XCTFail("Close bypassed the maintenance fence")
        } catch let failure as HistoryFailure { XCTAssertEqual(failure.cause, .busy) }
        recovery.resumeLookup()
        let engine = try await opening.value
        try await copying.value
        XCTAssertTrue(captured)
        XCTAssertTrue(engine.snapshot.canUndo)
        XCTAssertEqual(try Data(contentsOf: hostURL), originalHost)
        XCTAssertEqual(host.deliveries, 1)
        try await store.close()
        let copied = try await HistoryStore.open(at: copyURL, workingIdentity: UUID(),
            mode: .independentCopy(sourceWorkingIdentity: working))
        XCTAssertEqual(try copied.inspectScope(scope).pendingRecoveryCount, 0)
        XCTAssertEqual(try copied.historyPage(scope: scope, limit: 10).count, 1)
        try await copied.close()
    }

    private func assertWriterIsExclusivelyOwned(at url: URL, workingIdentity: UUID) async throws {
        do {
            let competitor = try await HistoryStore.open(at: url, workingIdentity: workingIdentity, mode: .existing)
            try await competitor.close()
            XCTFail("Opening recovery lost exclusive writer ownership")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .busy)
        }
    }

}
