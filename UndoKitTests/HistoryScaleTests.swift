// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import Foundation
import ScaleWorkload
import XCTest

@MainActor final class HistoryScaleTests: XCTestCase {
    func testBoundedWorkloadPreservesKnownDivergentStatesAndReopen() async throws {
        guard ProcessInfo.processInfo.environment["UNDOKIT_SCALE_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in: UNDOKIT_SCALE_SMOKE=1 scripts/test-package.sh --filter HistoryScaleTests; " +
                          "production evidence: scripts/check-undokit-scale.rb")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UndoKitScaleSmoke-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await ScaleWorkload.create(directory: directory, groups: 100, seed: 11)
        // Worked 100-group/seed-11 fixture: trunk 1, branch A 49, branch B 50.
        XCTAssertEqual(report.farBack.value, 1_100_002)
        XCTAssertEqual(report.divergent.value, 1_100_100)
        XCTAssertEqual(report.returnToDisplaced.value, 1_100_200)
        XCTAssertEqual(report.actionsPerGroup[2], 10)
        XCTAssertGreaterThan(report.removedGroups, 0)
        let reopened = try await ScaleWorkload.reopen(directory: directory)
        XCTAssertEqual(reopened.hostValue, 1_100_200)
        XCTAssertEqual(reopened.deliveries, 151)
        XCTAssertEqual(reopened.members, 166)
        // This XCTest readback is same-process; the command owns fresh-process proof.
    }
}
