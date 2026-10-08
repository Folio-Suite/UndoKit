// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor final class HistoryRetainedInterfaceTests: XCTestCase {
    private func accepted(_ engine: HistoryEngine, _ value: Int) async throws -> HistoryEntry {
        let command = HistoryCommand(fingerprint: Data("set \(value)".utf8), payload: payload(value))
        guard case .accepted(let receipt) = await engine.submit(command) else {
            throw HistoryFailure(.hostProtocol, stage: .delivery, disposition: .usable)
        }
        return try XCTUnwrap(engine.historyPage(limit: 10).first { $0.groupID == receipt.groupID })
    }

    private func assertBusy(_ operation: () throws -> Void,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? HistoryFailure)?.cause, .busy, file: file, line: line)
        }
    }

    func testLiveReadingPlanProtectsDetailAndDefersRecordingAndGenerationChanges() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(
            at: directory.appendingPathComponent("History.sqlite"), scope: UUID(),
            workingIdentity: UUID(), mode: .create, host: host,
            limits: HistoryLimits(maxUndoGroups: 1))
        let reader: any HistoryReading = engine
        let retention: any HistoryRetentionManaging = engine

        let first = try await accepted(engine, 1)
        _ = try await accepted(engine, 2)
        _ = try await accepted(engine, 3)
        let last = try await accepted(engine, 4)
        let boundary = try retention.createCheckpoint(
            id: UUID(), name: "Four", state: payload(4), resources: [])
        let generation = try reader.readIdentity().generation
        let plan = try reader.beginRecoveryPlan(
            from: .current, to: .group(first.groupID), using: .acceptedEffects)

        let protected = try retention.consolidateHistory(
            through: boundary.id, policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertEqual(protected.removedGroups, 0)
        XCTAssertTrue(protected.targetUnmet)
        XCTAssertEqual(try reader.recoveryPage(plan, after: nil, limit: 10).steps.count, 3)
        assertBusy { _ = try engine.setRecording(.off) }
        assertBusy { _ = try engine.clearHistory(adopting: payload(4)) }
        XCTAssertEqual(try reader.readIdentity().generation, generation)
        XCTAssertEqual(try engine.recordingMode(), .on)

        reader.releaseRecoveryPlan(plan)
        let consolidated = try retention.consolidateHistory(
            through: boundary.id, policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertEqual(consolidated.removedGroups, 3)
        XCTAssertEqual(try reader.historyPage(after: nil, limit: 10).map(\.groupID), [last.groupID])
        _ = try engine.setRecording(.off)
        XCTAssertEqual(try engine.recordingMode(), .off)
        _ = try engine.clearHistory(adopting: payload(4))
        XCTAssertNotEqual(try reader.readIdentity().generation, generation)
        try await engine.close()
    }

    func testClosingSessionInvalidatesReadingPlanAndReleasesPruningProtection() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let scope = UUID(), workingID = UUID()
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let limits = HistoryLimits(maxUndoGroups: 1)
        let engine = try await HistoryEngine.open(at: url, scope: scope, workingIdentity: workingID,
            mode: .create, host: host, limits: limits)
        let reader: any HistoryReading = engine
        let first = try await accepted(engine, 1)
        _ = try await accepted(engine, 2)
        let last = try await accepted(engine, 3)
        let boundary = try engine.createCheckpoint(name: "Three", state: payload(3))
        let plan = try reader.beginRecoveryPlan(
            from: .current, to: .group(first.groupID), using: .acceptedEffects)
        try await engine.close()

        assertBusy { _ = try reader.recoveryPage(plan, after: nil, limit: 10) }
        let reopened = try await HistoryEngine.open(at: url, scope: scope, workingIdentity: workingID,
            mode: .existing, host: host, limits: limits)
        let retained: any HistoryRetentionManaging = reopened
        let reopenedReader: any HistoryReading = reopened
        let result = try retained.consolidateHistory(
            through: boundary.id, policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertEqual(result.removedGroups, 2)
        XCTAssertEqual(try reopenedReader.historyPage(after: nil, limit: 10).map(\.groupID), [last.groupID])
        try await reopened.close()
    }
}
