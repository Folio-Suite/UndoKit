// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor final class HistoryReconstructionTests: XCTestCase {
    func testReversePlanReconstructsDisplacedContinuationWithoutMovingCurrentState() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host)
        for value in 1...3 {
            guard case .accepted = await engine.submit(HistoryCommand(
                fingerprint: Data("set \(value)".utf8), payload: payload(value))) else {
                return XCTFail("Command was not accepted")
            }
        }
        let displaced = try XCTUnwrap(engine.historyPage(limit: 10).last)
        guard case .accepted = await engine.undo() else { return XCTFail("Undo failed") }
        guard case .accepted = await engine.submit(HistoryCommand(
            fingerprint: Data("set 4".utf8), payload: payload(4))) else {
            return XCTFail("New branch failed")
        }
        XCTAssertEqual(host.value, 4)
        let before = engine.snapshot
        let plan = try engine.beginRecoveryPlan(to: .group(displaced.groupID), using: .acceptedEffects)
        XCTAssertEqual(plan.direction, .reverse)
        var reconstructed = host.value
        var cursor: Int64?
        var visited: [HistoryEntryKind] = []
        repeat {
            let page = try engine.recoveryPage(plan, after: cursor, limit: 1)
            for step in page.steps {
                visited.append(step.kind)
                for ordinal in (0..<step.memberCount).reversed() {
                    let material = try engine.recoveryMaterial(plan, groupID: step.groupID, ordinal: ordinal)
                    reconstructed = try XCTUnwrap(Int(String(decoding: material.payload.data, as: UTF8.self)))
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(visited, [.command, .undo])
        XCTAssertEqual(reconstructed, 3)
        XCTAssertEqual(host.value, 4)
        XCTAssertEqual(engine.snapshot, before)
        engine.releaseRecoveryPlan(plan)

        guard case .accepted = await engine.submit(HistoryCommand(
            fingerprint: Data("restore displaced".utf8), payload: payload(reconstructed),
            restorationOrigin: displaced.groupID)) else {
            return XCTFail("Restoration failed")
        }
        XCTAssertEqual(host.value, 3)
        guard case .accepted = await engine.undo() else { return XCTFail("Restoration Undo failed") }
        XCTAssertEqual(host.value, 4)
        try await engine.close()
    }

    func testCheckpointBaselinePagesForwardAndKeepsItsReadVersion() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host,
            limits: HistoryLimits(maxReadPage: 1))
        guard case .accepted = await engine.submit(HistoryCommand(
            fingerprint: Data("one".utf8), payload: payload(1))) else { return XCTFail("One failed") }
        let checkpoint = try engine.createCheckpoint(name: "One", state: payload(1))
        for value in 2...3 {
            guard case .accepted = await engine.submit(HistoryCommand(
                fingerprint: Data("set \(value)".utf8), payload: payload(value))) else {
                return XCTFail("Command failed")
            }
        }
        let target = try XCTUnwrap(engine.historyPage(after: 3, limit: 1).first)
        let identity = try engine.readIdentity()
        XCTAssertEqual(identity.committedVersion, 4)
        XCTAssertEqual(identity.latestAcceptedSequence, target.sequence)
        let plan = try engine.beginRecoveryPlan(from: .checkpoint(checkpoint.id),
            to: .group(target.groupID), using: .acceptedEffects)
        XCTAssertEqual(plan.committedVersion, identity.committedVersion)
        XCTAssertEqual(plan.direction, .forward)
        var reconstructed = try XCTUnwrap(Int(String(decoding:
            try XCTUnwrap(engine.recoveryCheckpoint(plan)).state.data, as: UTF8.self)))
        var cursor: Int64?
        var count = 0
        repeat {
            let page = try engine.recoveryPage(plan, after: cursor, limit: 1)
            for step in page.steps {
                count += 1
                let material = try engine.recoveryMaterial(plan, groupID: step.groupID, ordinal: 0)
                reconstructed = try XCTUnwrap(Int(String(decoding: material.payload.data, as: UTF8.self)))
            }
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(count, 2)
        XCTAssertEqual(reconstructed, 3)
        XCTAssertEqual(host.value, 3)
        engine.releaseRecoveryPlan(plan)
        try await engine.close()
    }

    func testMetadataResolvesNativeNameAndPlansReleaseOnCancelOrClose() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host,
            limits: HistoryLimits(maxRecoveryPlans: 1))
        let label = HistoryPayload(family: "test.label", data: Data("Set one".utf8))
        guard case .accepted = await engine.submit(HistoryCommand(
            fingerprint: Data("one".utf8), payload: payload(1), presentation: label)) else {
            return XCTFail("Command failed")
        }
        let group = try XCTUnwrap(engine.historyPage(limit: 1).first)
        XCTAssertEqual(try engine.presentation(forGroup: group.groupID), label)
        let native = try engine.nativeActionNames { String(data: $0.data, encoding: .utf8) }
        XCTAssertEqual(native.names.undo, "Set one")
        XCTAssertEqual(native.names.redo, "")
        XCTAssertEqual(native.snapshot, engine.snapshot)
        let first = try engine.beginRecoveryPlan(to: .group(group.groupID), using: .acceptedEffects)
        XCTAssertThrowsError(try engine.beginRecoveryPlan(to: .group(group.groupID),
            using: .acceptedEffects)) { error in
            XCTAssertEqual((error as? HistoryFailure)?.cause, .capacity)
        }
        engine.cancelRecoveryPlan(first)
        XCTAssertThrowsError(try engine.recoveryPage(first, limit: 1))
        let second = try engine.beginRecoveryPlan(to: .group(group.groupID), using: .acceptedEffects)
        try await engine.close()
        XCTAssertThrowsError(try engine.recoveryPage(second, limit: 1))
    }
}
