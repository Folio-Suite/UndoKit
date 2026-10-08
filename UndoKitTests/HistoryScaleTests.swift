// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor final class HistoryScaleTests: XCTestCase {
    func testFarBackAndDivergentReconstruction() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["UNDOKIT_SCALE_GROUPS"], let count = Int(raw),
              let root = environment["UNDOKIT_SCALE_DIRECTORY"] else {
            throw XCTSkip("Opt-in: run scripts/check-undokit-scale.rb")
        }
        guard (100...100_000).contains(count) else { XCTFail("Invalid scale size"); return }
        let directory = URL(fileURLWithPath: root)
        let host = ScaleHost()
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.cd"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host,
            limits: HistoryLimits(maxUndoGroups: 100, maxReadPage: 64))
        let buildStart = Date()
        var first: UUID?
        var firstCommand: HistoryCommand?
        var firstReceipt: HistoryReceipt?
        var last: UUID?
        for value in 1...count {
            let command = HistoryCommand(fingerprint: Data("set \(value)".utf8), payload: payload(value))
            let result = await engine.submit(command)
            guard case .accepted(let receipt) = result else {
                XCTFail("Fixture stopped at \(value): \(result)"); return
            }
            if first == nil {
                first = receipt.groupID
                firstCommand = command
                firstReceipt = receipt
            }
            last = receipt.groupID
        }
        print("SCALE fixture groups=\(count) seconds=\(Date().timeIntervalSince(buildStart))")
        let farStart = Date()
        let far = try engine.beginRecoveryPlan(to: .group(try XCTUnwrap(first)), using: .acceptedEffects)
        let farResult = try reconstruct(far, engine: engine, value: host.value)
        XCTAssertEqual(farResult.value, 1)
        XCTAssertEqual(farResult.steps, count - 1)
        engine.releaseRecoveryPlan(far)
        print("SCALE farBack steps=\(farResult.steps) seconds=\(Date().timeIntervalSince(farStart))")
        let reversals = min(100, count / 2)
        for _ in 0..<reversals {
            guard case .accepted = await engine.undo() else { XCTFail("Undo failed"); return }
        }
        guard case .accepted = await engine.submit(HistoryCommand(
            fingerprint: Data("branch".utf8), payload: payload(-1))) else {
            XCTFail("Divergent command failed"); return
        }
        let divergenceStart = Date()
        let branch = try engine.beginRecoveryPlan(to: .group(try XCTUnwrap(last)), using: .acceptedEffects)
        let branchResult = try reconstruct(branch, engine: engine, value: host.value)
        XCTAssertEqual(branchResult.value, count)
        XCTAssertEqual(branchResult.steps, reversals + 1)
        XCTAssertEqual(host.value, -1)
        engine.releaseRecoveryPlan(branch)
        print("SCALE divergent steps=\(branchResult.steps) seconds=\(Date().timeIntervalSince(divergenceStart))")
        let checkpoint = try engine.createCheckpoint(name: "Divergent current", state: payload(-1))
        let consolidationStart = Date()
        var removed = 0
        var passes = 0
        var more = true
        while more {
            let result = try engine.consolidateHistory(through: checkpoint.id,
                policy: HistoryRetentionPolicy(targetDetailedGroups: 100))
            removed += result.removedGroups
            passes += 1
            more = result.hasMore
            XCTAssertLessThan(passes, count / 64 + 20)
            if passes >= count / 64 + 20 { return }
        }
        XCTAssertGreaterThan(removed, 0)
        XCTAssertEqual(try engine.checkpoint(id: checkpoint.id)?.state, payload(-1))
        XCTAssertEqual(host.value, -1)
        let deliveredBeforeRetry = host.deliveries
        let retry = await engine.submit(try XCTUnwrap(firstCommand))
        XCTAssertEqual(retry, .accepted(try XCTUnwrap(firstReceipt)))
        XCTAssertEqual(host.deliveries, deliveredBeforeRetry)
        let consolidationSeconds = Date().timeIntervalSince(consolidationStart)
        print("SCALE consolidation removed=\(removed) passes=\(passes) seconds=\(consolidationSeconds)")
        try await engine.close()
    }

    private func reconstruct(_ plan: HistoryRecoveryPlan, engine: HistoryEngine,
                             value: Int) throws -> (value: Int, steps: Int) {
        var value = value
        var count = 0
        var cursor: Int64?
        repeat {
            let page = try engine.recoveryPage(plan, after: cursor, limit: 64)
            XCTAssertLessThanOrEqual(page.steps.count, 64)
            for step in page.steps {
                for ordinal in (0..<step.memberCount).reversed() {
                    let material = try engine.recoveryMaterial(plan, groupID: step.groupID, ordinal: ordinal)
                    value = try XCTUnwrap(Int((String(bytes: material.payload.data, encoding: .utf8) ?? "")))
                }
                count += 1
            }
            cursor = page.nextCursor
        } while cursor != nil
        return (value, count)
    }
}

/// This process-local fixture measures the history engine; crash recovery uses
/// the durable CounterHost tests. It does not model host database throughput.
@MainActor private final class ScaleHost: HistoryHost {
    var value = 0
    var deliveries = 0

    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        deliveries += 1
        var effects: [HistoryEffect] = []
        for member in delivery.members {
            guard let next = Int((String(bytes: member.payload.data, encoding: .utf8) ?? "")) else {
                return .rejected
            }
            effects.append(HistoryEffect(memberID: member.id, undo: payload(value), redo: payload(next)))
            value = next
        }
        return .accepted(effects)
    }

    func outcome(for token: HistoryToken) async -> HistoryHostOutcome { .unresolved }
}
