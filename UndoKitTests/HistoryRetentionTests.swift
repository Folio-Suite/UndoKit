// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor final class HistoryRetentionTests: XCTestCase {
    private func accepted(_ engine: HistoryEngine, _ value: Int) async throws -> HistoryEntry {
        let command = HistoryCommand(fingerprint: Data("set \(value)".utf8), payload: payload(value))
        guard case .accepted(let receipt) = await engine.submit(command) else {
            throw HistoryFailure(.hostProtocol, stage: .delivery, disposition: .usable)
        }
        return try XCTUnwrap(engine.historyPage(limit: 100).first { $0.groupID == receipt.groupID })
    }

    func testDetailHoldsResolveRepeatedGroupIDsWithinEachScope() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
            workingIdentity: UUID(), mode: .create)
        let firstHost = try CounterHost(url: directory.appendingPathComponent("first.json"))
        let secondHost = try CounterHost(url: directory.appendingPathComponent("second.json"))
        let first = try await store.openScope(UUID(), mode: .create, host: firstHost)
        let second = try await store.openScope(UUID(), mode: .create, host: secondHost)
        let command = HistoryCommand(id: UUID(), fingerprint: Data("one".utf8), payload: payload(1))
        guard case .accepted(let receipt) = await first.submit(command),
              case .accepted = await second.submit(command) else {
            return XCTFail("Independent scopes refused a shared command ID")
        }
        let firstHold = try first.holdDetail(from: receipt.groupID, through: receipt.groupID)
        let secondHold = try second.holdDetail(from: receipt.groupID, through: receipt.groupID)
        XCTAssertEqual(try first.retentionHolds().map(\.id), [firstHold.id])
        XCTAssertEqual(try second.retentionHolds().map(\.id), [secondHold.id])
        try first.releaseHold(firstHold.id)
        XCTAssertEqual(try second.retentionHolds().map(\.id), [secondHold.id])
        try await store.close()
    }

    func testStateAndOverlappingDetailHoldsSurviveReleaseAndReopen() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = UUID(), workingID = UUID()
        let url = directory.appendingPathComponent("History.sqlite")
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let limits = HistoryLimits(maxUndoGroups: 1)
        let engine = try await HistoryEngine.open(at: url, scope: scope, workingIdentity: workingID,
            mode: .create, host: host, limits: limits)
        let first = try await accepted(engine, 1)
        let second = try await accepted(engine, 2)
        let state = try engine.createCheckpoint(name: "Two", state: payload(2))
        let third = try await accepted(engine, 3)
        _ = try await accepted(engine, 4)
        let boundary = try engine.createCheckpoint(name: "Four", state: payload(4))
        let stateHold = try engine.holdState(state.id)
        let firstHold = try engine.holdDetail(from: first.groupID, through: second.groupID)
        let overlap = try engine.holdDetail(from: second.groupID, through: third.groupID)
        try engine.releaseHold(firstHold.id)
        let pass = try engine.consolidateHistory(through: boundary.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertEqual(pass.removedGroups, 1)
        XCTAssertTrue(pass.targetUnmet)
        XCTAssertEqual(try engine.historyPage(limit: 20).map(\.groupID),
                       [second.groupID, third.groupID, try engine.historyPage(limit: 20).last!.groupID])
        XCTAssertEqual(try engine.checkpoint(id: state.id)?.state, payload(2))
        try await engine.close()

        let reopened = try await HistoryEngine.open(at: url, scope: scope, workingIdentity: workingID,
            mode: .existing, host: host, limits: limits)
        XCTAssertEqual(Set(try reopened.retentionHolds().map(\.id)), [stateHold.id, overlap.id])
        try reopened.releaseHold(overlap.id)
        _ = try reopened.consolidateHistory(through: boundary.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertEqual(try reopened.historyPage(limit: 20).count, 1)
        XCTAssertEqual(try reopened.checkpoint(id: state.id)?.state, payload(2))
        try reopened.releaseHold(stateHold.id)
        _ = try reopened.consolidateHistory(through: boundary.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertNil(try reopened.checkpoint(id: state.id))
        try await reopened.close()
    }

    func testActiveRecoveryPlanProtectsReverseTargetAndReleaseAllowsGap() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host,
            limits: HistoryLimits(maxUndoGroups: 1))
        let first = try await accepted(engine, 1)
        _ = try await accepted(engine, 2)
        _ = try await accepted(engine, 3)
        let last = try await accepted(engine, 4)
        let boundary = try engine.createCheckpoint(name: "Four", state: payload(4))
        let plan = try engine.beginRecoveryPlan(to: .group(first.groupID), using: .acceptedEffects)
        let protected = try engine.consolidateHistory(through: boundary.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertEqual(protected.removedGroups, 0)
        XCTAssertEqual(try engine.recoveryPage(plan, limit: 10).steps.count, 3)
        engine.releaseRecoveryPlan(plan)
        let removed = try engine.consolidateHistory(through: boundary.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertEqual(removed.removedGroups, 3)
        XCTAssertEqual(try engine.historyPage(limit: 10).map(\.groupID), [last.groupID])
        XCTAssertThrowsError(try engine.beginRecoveryPlan(to: .group(first.groupID),
            using: .acceptedEffects)) { error in
            XCTAssertEqual((error as? HistoryFailure)?.cause, .compatibility)
        }
        try await engine.close()
    }

    func testConsolidationKeepsRetryIdentityAndRefusesCrossGapRecovery() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host,
            limits: HistoryLimits(maxUndoGroups: 1))
        _ = try await accepted(engine, 1)
        let early = try engine.createCheckpoint(name: "One", state: payload(1))
        let command = HistoryCommand(fingerprint: Data("two".utf8), payload: payload(2))
        guard case .accepted(let receipt) = await engine.submit(command) else {
            return XCTFail("Command failed")
        }
        let last = try await accepted(engine, 3)
        let late = try engine.createCheckpoint(name: "Three", state: payload(3))
        let result = try engine.consolidateHistory(through: late.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0, keptCheckpointIDs: [early.id]))
        XCTAssertEqual(result.removedGroups, 2)
        let deliveries = host.deliveries
        let retry = await engine.submit(command)
        XCTAssertEqual(retry, .accepted(receipt))
        XCTAssertEqual(host.deliveries, deliveries)
        let conflict = HistoryCommand(id: command.id, fingerprint: Data("different".utf8), payload: payload(9))
        guard case .failure(let failure) = await engine.submit(conflict) else {
            return XCTFail("Changed intent was not refused")
        }
        XCTAssertEqual(failure.cause, .identityConflict)
        XCTAssertEqual(host.deliveries, deliveries)
        XCTAssertThrowsError(try engine.beginRecoveryPlan(from: .checkpoint(early.id),
            to: .group(last.groupID), using: .acceptedEffects)) { error in
            XCTAssertEqual((error as? HistoryFailure)?.cause, .compatibility)
        }
        let checkpointPlan = try engine.beginRecoveryPlan(to: .checkpoint(early.id),
            using: .acceptedEffects)
        XCTAssertEqual(try engine.recoveryCheckpoint(checkpointPlan)?.state, payload(1))
        engine.releaseRecoveryPlan(checkpointPlan)
        try await engine.close()
    }

    func testSharedResourcesAndCleanupRetryAcrossScopes() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let workingID = UUID(), firstScope = UUID(), secondScope = UUID()
        let storeID = UUID()
        let shared = HistoryObjectReference(storeID: storeID, objectKey: "photo", versionKey: "v1")
        let store = try await HistoryStore.open(at: url, workingIdentity: workingID,
            mode: .create, limits: HistoryLimits(maxUndoGroups: 1))
        let firstHost = try CounterHost(url: directory.appendingPathComponent("first.json"))
        let secondHost = try CounterHost(url: directory.appendingPathComponent("second.json"))
        firstHost.resourcesByValue[1] = [shared]
        secondHost.resourcesByValue[1] = [shared]
        let first = try await store.openScope(firstScope, mode: .create, host: firstHost)
        let second = try await store.openScope(secondScope, mode: .create, host: secondHost)
        _ = try await accepted(first, 1)
        _ = try await accepted(second, 1)
        let sharedCheckpointID = UUID()
        _ = try first.createCheckpoint(id: sharedCheckpointID, name: "One", state: payload(1),
                                       resources: [shared])
        _ = try second.createCheckpoint(id: sharedCheckpointID, name: "One", state: payload(1),
                                        resources: [shared])
        _ = try await accepted(first, 2)
        _ = try await accepted(second, 2)
        let firstBoundary = try first.createCheckpoint(name: "Two", state: payload(2))
        let secondBoundary = try second.createCheckpoint(name: "Two", state: payload(2))
        XCTAssertEqual(try store.requiredObjects(in: storeID, limit: 10).objects.first?.referenceCount, 4)
        _ = try first.consolidateHistory(through: firstBoundary.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertEqual(try store.requiredObjects(in: storeID, limit: 10).objects.first?.referenceCount, 2)
        _ = try second.consolidateHistory(through: secondBoundary.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertTrue(try store.requiredObjects(in: storeID, limit: 10).objects.isEmpty)
        XCTAssertTrue(try store.cleanupPending(for: storeID))
        enum CleanupError: Error { case interrupted }
        do {
            try await store.withRequiredObjects(in: storeID) { _ in throw CleanupError.interrupted }
            XCTFail("Interrupted cleanup succeeded")
        } catch CleanupError.interrupted {}
        try await store.close()
        let reopened = try await HistoryStore.open(at: url, workingIdentity: workingID,
            mode: .existing, limits: HistoryLimits(maxUndoGroups: 1))
        XCTAssertTrue(try reopened.cleanupPending(for: storeID))
        try await reopened.withRequiredObjects(in: storeID) { fenced in
            XCTAssertTrue(try fenced.requiredObjects(in: storeID, limit: 10).objects.isEmpty)
        }
        XCTAssertFalse(try reopened.cleanupPending(for: storeID))
        let reader = try await HistoryStore.open(at: url, workingIdentity: workingID,
            mode: .existing, access: .readOnly)
        do {
            try await reader.withRequiredObjects(in: storeID) { _ in }
            XCTFail("Read-only cleanup succeeded")
        } catch let failure as HistoryFailure { XCTAssertEqual(failure.cause, .busy) }
        try await reader.close()
        try await reopened.close()
    }

    func testOrdinaryDepthWinsOverTargetAndCancelledPassDoesNotPrune() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host,
            limits: HistoryLimits(maxPayloadBytes: 16, maxUndoGroups: 2))
        for value in 1...4 { _ = try await accepted(engine, value) }
        let boundary = try engine.createCheckpoint(name: "Four", state: payload(4))
        let held = try engine.holdState(boundary.id)
        let cancelled = Task { () -> HistoryFailure? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try engine.consolidateHistory(through: boundary.id,
                    policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
                return nil
            } catch { return error as? HistoryFailure }
        }
        let cancellationFailure = await cancelled.value
        XCTAssertEqual(cancellationFailure?.cause, .cancelled)
        XCTAssertEqual(try engine.historyPage(limit: 10).count, 4)
        let oversized = HistoryCommand(fingerprint: Data("large".utf8),
            payload: HistoryPayload(family: "counter.set", data: Data(repeating: 0, count: 17)))
        guard case .failure(let capacity) = await engine.submit(oversized) else {
            return XCTFail("Hard payload limit did not refuse admission")
        }
        XCTAssertEqual(capacity.cause, .capacity)
        XCTAssertEqual(try engine.retentionHolds().map(\.id), [held.id])
        let result = try engine.consolidateHistory(through: boundary.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertEqual(result.removedGroups, 2)
        XCTAssertEqual(result.retainedGroups, 2)
        XCTAssertTrue(result.targetUnmet)
        guard case .accepted = await engine.undo(), case .accepted = await engine.undo() else {
            return XCTFail("Ordinary two-group depth was shortened")
        }
        XCTAssertEqual(host.value, 2)
        XCTAssertFalse(engine.snapshot.canUndo)
        XCTAssertTrue(engine.snapshot.canRedo)
        try await engine.close()
    }

    func testBranchedDetailSurvivesItsHoldAndPrunesAfterRelease() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host,
            limits: HistoryLimits(maxUndoGroups: 1))
        _ = try await accepted(engine, 1)
        let displaced = try await accepted(engine, 2)
        guard case .accepted = await engine.undo() else { return XCTFail("Undo failed") }
        _ = try await accepted(engine, 3)
        let boundary = try engine.createCheckpoint(name: "Three", state: payload(3))
        let hold = try engine.holdDetail(from: displaced.groupID, through: displaced.groupID)
        _ = try engine.consolidateHistory(through: boundary.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertTrue(try engine.historyPage(limit: 10).contains { $0.groupID == displaced.groupID })
        try engine.releaseHold(hold.id)
        _ = try engine.consolidateHistory(through: boundary.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertEqual(try engine.historyPage(limit: 10).count, 1)
        XCTAssertEqual(host.value, 3)
        try await engine.close()
    }

    func testCleanupWaitsForOtherScopeToReconcileAcceptedOutcome() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let identity = UUID(), firstScope = UUID(), secondScope = UUID(), retentionStore = UUID()
        let store = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .create)
        let firstHost = try CounterHost(url: directory.appendingPathComponent("first.json"))
        let secondHost = try CounterHost(url: directory.appendingPathComponent("second.json"))
        let first = try await store.openScope(firstScope, mode: .create, host: firstHost)
        let second = try await store.openScope(secondScope, mode: .create, host: secondHost)
        _ = try await accepted(first, 1)
        secondHost.loseReplyAfterSave = true
        guard case .failure = await second.submit(HistoryCommand(
            fingerprint: Data("set two".utf8), payload: payload(2))) else {
            return XCTFail("Second scope did not retain unresolved evidence")
        }
        var cleaned = false
        do {
            try await store.withRequiredObjects(in: retentionStore) { _ in cleaned = true }
            XCTFail("Cleanup crossed an unresolved scope")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .unresolved)
        }
        XCTAssertFalse(cleaned)
        try await store.close()
        let reopened = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .existing)
        let reconciled = try await reopened.openScope(secondScope, mode: .existing, host: secondHost)
        XCTAssertFalse(reconciled.snapshot.isSuspended)
        try await reopened.withRequiredObjects(in: retentionStore) { _ in cleaned = true }
        XCTAssertTrue(cleaned)
        try await reopened.close()
    }

    func testEmptyVersionKeyIsRefusedAndNilRemainsUnversioned() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let retentionStore = UUID()
        let invalid = HistoryObjectReference(storeID: retentionStore,
                                             objectKey: "image", versionKey: "")
        let unversioned = HistoryObjectReference(storeID: retentionStore, objectKey: "image")
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
            workingIdentity: UUID(), mode: .create)
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await store.openScope(UUID(), mode: .create, host: host)
        XCTAssertThrowsError(try engine.createCheckpoint(name: "Invalid", state: payload(0),
                                                          resources: [invalid])) { error in
            XCTAssertEqual((error as? HistoryFailure)?.cause, .capacity)
        }
        XCTAssertTrue(try engine.checkpoints(limit: 10).isEmpty)
        let checkpoint = try engine.createCheckpoint(name: "Unversioned", state: payload(0),
                                                     resources: [unversioned])
        XCTAssertNotNil(try engine.checkpoint(id: checkpoint.id))
        XCTAssertThrowsError(try store.requiredObjects(in: retentionStore,
            after: HistoryObjectReference(storeID: retentionStore, objectKey: "cursor", versionKey: ""),
            limit: 10))
        let required = try store.requiredObjects(in: retentionStore, limit: 10)
        XCTAssertEqual(required.objects.map(\.reference), [unversioned])
        XCTAssertEqual(required.objects.first?.referenceCount, 1)

        host.resourcesByValue[1] = [invalid]
        let outcome = await engine.submit(HistoryCommand(
            fingerprint: Data("one".utf8), payload: payload(1)))
        guard case .failure(let failure) = outcome else {
            return XCTFail("Invalid accepted-effect reference was retained")
        }
        XCTAssertEqual(failure.cause, .hostProtocol)
        XCTAssertEqual(failure.disposition, .suspended)
        XCTAssertEqual(host.value, 1)
        XCTAssertTrue(try engine.historyPage(limit: 10).isEmpty)
        XCTAssertEqual(try store.requiredObjects(in: retentionStore, limit: 10).objects,
                       required.objects)
        try await store.close()
    }
}
