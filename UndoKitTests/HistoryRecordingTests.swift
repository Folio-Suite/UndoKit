// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor private final class RecordingCounterHost: HistoryHost {
    var value = 0
    var deliveries = 0
    var requiredResource: HistoryObjectReference?
    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        deliveries += 1
        guard delivery.members.count == 1,
              let text = String(data: delivery.members[0].payload.data, encoding: .utf8),
              let delta = Int(text) else { return .rejected }
        value += delta
        let member = delivery.members[0]
        return .accepted([HistoryEffect(memberID: member.id,
            undo: HistoryPayload(family: "counter", data: Data(String(-delta).utf8)),
            redo: member.payload,
            resources: requiredResource.map { [$0] } ?? [])])
    }
    func outcome(for token: HistoryToken) async -> HistoryHostOutcome { .unresolved }
}

@MainActor private final class UnresolvedRecordingHost: HistoryHost {
    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome { .unresolved }
    func outcome(for token: HistoryToken) async -> HistoryHostOutcome { .unresolved }
}

@MainActor private final class AcceptedOnRecoveryHost: HistoryHost {
    var delivery: HistoryDelivery?
    let resource = HistoryObjectReference(storeID: UUID(), objectKey: "required")
    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        self.delivery = delivery
        return .unresolved
    }
    func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        guard let delivery, delivery.token == token, let member = delivery.members.first else {
            return .unresolved
        }
        return .accepted([HistoryEffect(memberID: member.id,
            undo: HistoryPayload(family: "counter", data: Data("-1".utf8)),
            redo: member.payload, resources: [resource])])
    }
}

@MainActor final class HistoryRecordingTests: XCTestCase {
    func testRecordingOffKeepsSessionUndoAndRetainedCheckpointsWithoutGapActions() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let scope = UUID(), workingID = UUID()
        let host = RecordingCounterHost()
        let engine = try await HistoryEngine.open(at: url, scope: scope,
            workingIdentity: workingID, mode: .create, host: host)
        func command(_ delta: Int) -> HistoryCommand {
            HistoryCommand(fingerprint: Data(UUID().uuidString.utf8),
                payload: HistoryPayload(family: "counter", data: Data(String(delta).utf8)))
        }
        guard case .accepted = await engine.submit(command(1)) else { return XCTFail("initial edit") }
        _ = try engine.createCheckpoint(name: "Before gap",
            state: HistoryPayload(family: "counter", data: Data("1".utf8)))
        try engine.setRecording(.off)
        guard case .accepted = await engine.submit(command(2)) else { return XCTFail("Off edit") }
        XCTAssertEqual(host.value, 3)
        XCTAssertEqual(try engine.historyPage(limit: 10).count, 1)
        XCTAssertTrue(engine.snapshot.canUndo)
        guard case .accepted = await engine.undo() else { return XCTFail("session Undo") }
        XCTAssertEqual(host.value, 1)
        XCTAssertEqual(try engine.historyPage(limit: 10).count, 1)
        XCTAssertEqual(try engine.checkpoints(limit: 10).count, 1)
        try await engine.close()

        let reopened = try await HistoryEngine.open(at: url, scope: scope,
            workingIdentity: workingID, mode: .existing, host: host)
        XCTAssertFalse(reopened.snapshot.canUndo)
        XCTAssertEqual(try reopened.historyPage(limit: 10).count, 1)
        XCTAssertEqual(try reopened.checkpoints(limit: 10).count, 1)
        try await reopened.close()
    }

    func testOffSessionProtectsRequiredObjectsUntilSessionCloses() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = UUID(), workingID = UUID(), storeID = UUID()
        let host = RecordingCounterHost()
        host.requiredResource = HistoryObjectReference(storeID: storeID, objectKey: "version-1")
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
            workingIdentity: workingID, mode: .create)
        let engine = try await store.openScope(scope, mode: .create, host: host)
        try engine.setRecording(.off)
        let command = HistoryCommand(fingerprint: Data("resource".utf8),
            payload: HistoryPayload(family: "counter", data: Data("1".utf8)))
        guard case .accepted = await engine.submit(command) else { return XCTFail("Off edit") }
        XCTAssertEqual(try store.requiredObjects(in: storeID, limit: 10).objects.count, 1)
        try await engine.close()
        XCTAssertTrue(try store.requiredObjects(in: storeID, limit: 10).objects.isEmpty)
        XCTAssertTrue(try store.cleanupPending(for: storeID))
        try await store.close()
    }

    func testReenableAdoptsCoherentBaselineAndCannotReconstructAcrossOffGap() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = RecordingCounterHost()
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host)
        func command(_ delta: Int) -> HistoryCommand {
            HistoryCommand(fingerprint: Data(UUID().uuidString.utf8),
                payload: HistoryPayload(family: "counter", data: Data(String(delta).utf8)))
        }
        guard case .accepted(let before) = await engine.submit(command(1)) else { return XCTFail("before") }
        try engine.setRecording(.off)
        guard case .accepted = await engine.submit(command(2)) else { return XCTFail("gap") }
        XCTAssertNil(try engine.readIdentity().latestGroupID)
        XCTAssertThrowsError(try engine.beginRecoveryPlan(to: .group(before.groupID),
            using: .acceptedEffects))
        let baseline = try engine.setRecording(.on,
            baseline: HistoryPayload(family: "counter", data: Data("3".utf8)))
        XCTAssertNotNil(baseline)
        XCTAssertEqual(try engine.checkpoint(id: baseline!)?.state.data, Data("3".utf8))
        XCTAssertNil(try engine.readIdentity().latestGroupID)
        guard case .accepted = await engine.submit(command(4)) else { return XCTFail("after") }
        XCTAssertNotNil(try engine.readIdentity().latestGroupID)
        XCTAssertEqual(host.value, 7)
        XCTAssertEqual(try engine.historyPage(limit: 10).count, 2)
        XCTAssertThrowsError(try engine.beginRecoveryPlan(to: .group(before.groupID),
            using: .acceptedEffects))
        try await engine.close()
    }

    func testTurningOffKeepsExistingUndoUntilAnOffOperationIsAccepted() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = RecordingCounterHost()
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host)
        let command = HistoryCommand(fingerprint: Data("first".utf8),
            payload: HistoryPayload(family: "counter", data: Data("5".utf8)))
        guard case .accepted = await engine.submit(command) else { return XCTFail("first") }
        try engine.setRecording(.off)
        XCTAssertTrue(engine.snapshot.canUndo)
        guard case .accepted = await engine.undo() else { return XCTFail("Off Undo") }
        XCTAssertEqual(host.value, 0)
        XCTAssertTrue(engine.snapshot.canRedo)
        guard case .accepted = await engine.redo() else { return XCTFail("Off Redo") }
        XCTAssertEqual(host.value, 5)
        XCTAssertEqual(try engine.historyPage(limit: 10).count, 1)
        try await engine.close()
    }

    func testClearHistoryStartsNewGenerationWithoutRemovingAnotherScope() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
            workingIdentity: UUID(), mode: .create)
        let host = RecordingCounterHost()
        let first = try await store.openScope(UUID(), mode: .create, host: host)
        let second = try await store.openScope(UUID(), mode: .create, host: host)
        let command = HistoryCommand(fingerprint: Data("one".utf8),
            payload: HistoryPayload(family: "counter", data: Data("1".utf8)))
        guard case .accepted = await first.submit(command) else { return XCTFail("first") }
        guard case .accepted = await second.submit(command) else { return XCTFail("second") }
        let oldGeneration = first.snapshot.generation
        let baseline = HistoryPayload(family: "counter", data: Data("2".utf8))
        let newGeneration = try first.clearHistory(adopting: baseline)
        XCTAssertNotEqual(newGeneration, oldGeneration)
        XCTAssertFalse(first.snapshot.canUndo)
        XCTAssertTrue(try first.historyPage(limit: 10).isEmpty)
        XCTAssertEqual(try first.checkpoints(limit: 10).count, 1)
        XCTAssertEqual(try second.historyPage(limit: 10).count, 1)
        let delivered = host.deliveries
        guard case .failure(let stale) = await first.submit(command) else {
            return XCTFail("Old command was redelivered")
        }
        XCTAssertEqual(stale.cause, .identityConflict)
        let fresh = HistoryCommand(fingerprint: Data("fresh".utf8),
            payload: HistoryPayload(family: "counter", data: Data("2".utf8)))
        guard case .failure(let unbound) = await first.submit(fresh) else {
            return XCTFail("Unbound command crossed generation reset")
        }
        XCTAssertEqual(unbound.cause, .identityConflict)
        XCTAssertEqual(host.deliveries, delivered)
        let attached = HistoryCommand(fingerprint: fresh.fingerprint,
            payload: fresh.members[0].payload, expectedGeneration: newGeneration)
        guard case .accepted = await first.submit(attached) else {
            return XCTFail("Current generation command refused")
        }
        XCTAssertEqual(host.deliveries, delivered + 1)
        try await first.close()
        try await second.close()
        try await store.close()
    }

    func testUnresolvedResetRequiresQuarantineAndPreservesEvidence() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let quarantine = directory.appendingPathComponent("Quarantine.sqlite")
        let scope = UUID(), workingID = UUID()
        let host = UnresolvedRecordingHost()
        let engine = try await HistoryEngine.open(at: url, scope: scope,
            workingIdentity: workingID, mode: .create, host: host)
        let command = HistoryCommand(fingerprint: Data("unresolved".utf8),
            payload: HistoryPayload(family: "counter", data: Data("1".utf8)))
        guard case .failure = await engine.submit(command) else { return XCTFail("unresolved") }
        XCTAssertThrowsError(try engine.clearHistory(adopting:
            HistoryPayload(family: "counter", data: Data("1".utf8))))
        let oldGeneration = engine.snapshot.generation
        let newGeneration = try engine.resetUnresolvedHistory(
            adopting: HistoryPayload(family: "counter", data: Data("1".utf8)),
            quarantineAt: quarantine)
        XCTAssertNotEqual(newGeneration, oldGeneration)
        XCTAssertFalse(engine.snapshot.isSuspended)
        XCTAssertFalse(engine.snapshot.canUndo)
        let retained = try await HistoryStore.open(at: quarantine, workingIdentity: workingID,
            mode: .existing, access: .readOnly)
        XCTAssertEqual(try retained.inspectScope(scope).generation, oldGeneration)
        XCTAssertEqual(try retained.inspectScope(scope).pendingRecoveryCount, 1)
        try await retained.close()
        try await engine.close()
    }

    func testOffThenOnWithoutAcceptedEditKeepsEarlierUndo() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = RecordingCounterHost()
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host)
        let command = HistoryCommand(fingerprint: Data("first".utf8),
            payload: HistoryPayload(family: "counter", data: Data("1".utf8)))
        guard case .accepted = await engine.submit(command) else { return XCTFail("first") }
        try engine.setRecording(.off)
        _ = try engine.setRecording(.on,
            baseline: HistoryPayload(family: "counter", data: Data("1".utf8)))
        XCTAssertTrue(engine.snapshot.canUndo)
        guard case .accepted = await engine.undo() else { return XCTFail("prior Undo was lost") }
        XCTAssertEqual(host.value, 0)
        try await engine.close()
    }

    func testInterruptedOffAcceptanceDoesNotRestoreSessionUndoOnReopen() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let scope = UUID(), workingID = UUID()
        let host = AcceptedOnRecoveryHost()
        let engine = try await HistoryEngine.open(at: url, scope: scope,
            workingIdentity: workingID, mode: .create, host: host)
        try engine.setRecording(.off)
        let command = HistoryCommand(fingerprint: Data("pending".utf8),
            payload: HistoryPayload(family: "counter", data: Data("1".utf8)))
        guard case .failure = await engine.submit(command) else { return XCTFail("pending") }
        try await engine.close()
        let store = try await HistoryStore.open(at: url, workingIdentity: workingID, mode: .existing)
        let reopened = try await store.openScope(scope, mode: .existing, host: host)
        XCTAssertFalse(reopened.snapshot.isSuspended)
        XCTAssertFalse(reopened.snapshot.canUndo)
        XCTAssertTrue(try reopened.historyPage(limit: 10).isEmpty)
        XCTAssertTrue(try store.requiredObjects(in: host.resource.storeID, limit: 10).objects.isEmpty)
        try await reopened.close()
        try await store.close()
    }
}
