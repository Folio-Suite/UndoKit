// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

extension UndoKitTests {
    func testDuplicateIdentityDoesNotRedeliverAndChangedIntentConflicts() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(
            at: directory.appendingPathComponent("History.sqlite"), scope: UUID(),
            workingIdentity: UUID(), mode: .create, host: host
        )
        let id = UUID()
        let original = HistoryCommand(id: id, fingerprint: Data("set 4".utf8), payload: payload(4))
        guard case .accepted(let first) = await engine.submit(original) else {
            XCTFail("First command failed")
            return
        }
        guard case .accepted(let retry) = await engine.submit(original) else {
            XCTFail("Retry failed")
            return
        }
        XCTAssertEqual(first, retry)
        XCTAssertEqual(host.deliveries, 1)
        let conflict = HistoryCommand(id: id, fingerprint: Data("set 5".utf8), payload: payload(5))
        guard case .failure(let failure) = await engine.submit(conflict) else {
            XCTFail("Identity reused for changed intent")
            return
        }
        XCTAssertEqual(failure.cause, .identityConflict)
        XCTAssertEqual(host.value, 4)
        XCTAssertEqual(host.deliveries, 1)
        try await engine.close()
    }

    func testHardCapacityRefusesBeforeHostDelivery() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(
            at: directory.appendingPathComponent("History.sqlite"), scope: UUID(),
            workingIdentity: UUID(), mode: .create, host: host,
            limits: HistoryLimits(maxPayloadBytes: 1)
        )
        let result = await engine.submit(HistoryCommand(fingerprint: Data("set 10".utf8), payload: payload(10)))
        guard case .failure(let failure) = result else {
            XCTFail("Oversized payload accepted")
            return
        }
        XCTAssertEqual(failure.cause, .capacity)
        XCTAssertEqual(failure.stage, .admission)
        XCTAssertEqual(host.deliveries, 0)
        XCTAssertEqual(host.value, 0)
        try await engine.close()
    }

    func testConcurrentSubmissionPreservesAdmissionOrderAcrossHostSuspension() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(
            at: directory.appendingPathComponent("History.sqlite"), scope: UUID(),
            workingIdentity: UUID(), mode: .create, host: host
        )
        host.pauseBeforeSave = true
        let first = Task { await engine.submit(HistoryCommand(fingerprint: Data("first".utf8), payload: payload(1))) }
        for _ in 0..<100 where host.deliveries == 0 { await Task.yield() }
        XCTAssertEqual(host.deliveries, 1)
        let second = Task { await engine.submit(HistoryCommand(fingerprint: Data("second".utf8), payload: payload(2))) }
        await Task.yield()
        XCTAssertEqual(host.deliveries, 1)
        XCTAssertTrue(engine.snapshot.hasPending)
        host.resumeDelivery()
        guard case .accepted = await first.value else {
            XCTFail("First submission failed")
            return
        }
        guard case .accepted = await second.value else {
            XCTFail("Second submission failed")
            return
        }
        XCTAssertEqual(host.deliveries, 2)
        XCTAssertEqual(host.value, 2)
        try await engine.close()
    }

    func testCancellationWhileQueuedNeverPreparesOrDeliversCommand() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(
            at: directory.appendingPathComponent("History.sqlite"), scope: UUID(),
            workingIdentity: UUID(), mode: .create, host: host
        )
        host.pauseBeforeSave = true
        let first = Task { await engine.submit(HistoryCommand(fingerprint: Data("first".utf8), payload: payload(1))) }
        for _ in 0..<100 where host.deliveries == 0 { await Task.yield() }
        let queued = Task { await engine.submit(HistoryCommand(fingerprint: Data("cancel".utf8), payload: payload(2))) }
        await Task.yield()
        queued.cancel()
        guard case .failure(let failure) = await queued.value else {
            XCTFail("Cancelled queued command ran")
            return
        }
        XCTAssertEqual(failure.cause, .cancelled)
        host.resumeDelivery()
        guard case .accepted = await first.value else {
            XCTFail("First command failed")
            return
        }
        XCTAssertEqual(host.deliveries, 1)
        XCTAssertEqual(try engine.historyPage(limit: 10).count, 1)
        try await engine.close()
    }
}
