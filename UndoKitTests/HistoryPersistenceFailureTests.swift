// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
@testable import UndoKit
import XCTest

@MainActor final class HistoryPersistenceFailureTests: XCTestCase {
    private let resourceBytes = Data("Required recovery resource v1".utf8)

    #if DEBUG
    func testSaveFailureAfterPreflightPreservesHostAndAllowsFreshSession() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let command = HistoryCommand(fingerprint: Data("set seven".utf8), payload: PersistenceEvidenceHost.payload(7))
        let result = await HistoryScopeStorage.$failSaveAt.withValue(.preparation) {
            await fixture.engine.submit(command)
        }
        assertStorageFailure(result, stage: .preparation)
        XCTAssertTrue(fixture.engine.snapshot.isSuspended)
        XCTAssertEqual(try fixture.engine.historyPage(limit: 10).count, 0)
        let freshHost = try PersistenceEvidenceHost(directory: fixture.directory, resource: fixture.resource)
        XCTAssertEqual(freshHost.value, 0)
        XCTAssertEqual(freshHost.deliveryCount, 0)
        XCTAssertEqual(freshHost.receipts.count, 0)
        XCTAssertEqual(try Data(contentsOf: freshHost.resourceURL), resourceBytes)
        try await fixture.store.close()
        let reopened = try await HistoryStore.open(at: fixture.store.url,
            workingIdentity: fixture.identity, mode: .existing)
        let engine = try await reopened.openScope(fixture.scope, mode: .existing, host: freshHost)
        XCTAssertFalse(engine.snapshot.isSuspended)
        guard case .accepted = await engine.submit(command) else {
            XCTFail("Fresh session could not retry")
            return
        }
        XCTAssertEqual(freshHost.value, 7)
        XCTAssertEqual(freshHost.applicationCount, 1)
        XCTAssertEqual(try engine.historyPage(limit: 10).map(\.groupID), [command.id])
        try await reopened.close()
    }
    func testAcceptedOutcomesRecoverWholeGroupWithoutRepeatingHostEffects() async throws {
        for point in [HistoryScopeStorage.FailurePoint.acceptanceEvidence, .acceptedFinalization] {
            let fixture = try await makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let command = HistoryCommand(fingerprint: Data("atomic four then seven".utf8), members: [
                HistoryMember(payload: PersistenceEvidenceHost.payload(4)),
                HistoryMember(payload: PersistenceEvidenceHost.payload(7)),
            ])
            let result = await HistoryScopeStorage.$failSaveAt.withValue(point) {
                await fixture.engine.submit(command)
            }
            assertStorageFailure(result, stage: .finalization)
            XCTAssertTrue(fixture.engine.snapshot.isSuspended)
            XCTAssertEqual(try fixture.engine.historyPage(limit: 10).count, 0)
            XCTAssertEqual(try fixture.store.inspectScope(fixture.scope).pendingRecoveryCount, 1)
            let freshHost = try PersistenceEvidenceHost(directory: fixture.directory, resource: fixture.resource)
            XCTAssertEqual(freshHost.value, 7)
            XCTAssertEqual(freshHost.applicationCount, 1)
            let receipt = try XCTUnwrap(freshHost.receipts.first)
            XCTAssertEqual(receipt.command, command.id)
            XCTAssertEqual(receipt.effects.map(\.member), command.members.map(\.id))
            XCTAssertEqual(receipt.effects.map(\.before), [0, 4])
            XCTAssertEqual(try Data(contentsOf: freshHost.resourceURL), resourceBytes)
            if point == .acceptedFinalization {
                XCTAssertEqual(try fixture.store.requiredObjects(in: fixture.resource.storeID, limit: 10)
                    .objects.map(\.reference), [fixture.resource])
            }
            let hostBytes = try Data(contentsOf: freshHost.url)
            try await fixture.store.close()
            let reopened = try await HistoryStore.open(at: fixture.store.url,
                workingIdentity: fixture.identity, mode: .existing)
            let engine = try await reopened.openScope(fixture.scope, mode: .existing, host: freshHost)
            XCTAssertFalse(engine.snapshot.isSuspended)
            XCTAssertEqual(try reopened.inspectScope(fixture.scope).pendingRecoveryCount, 0)
            let groups = try engine.historyPage(limit: 10)
            XCTAssertEqual(groups.map(\.groupID), [command.id])
            XCTAssertEqual(groups.map(\.memberCount), [2])
            guard case .accepted(let recovered) = await engine.submit(command) else {
                XCTFail("Recovered Command identity was not retained")
                return
            }
            XCTAssertEqual(recovered.token.command, receipt.command)
            XCTAssertEqual(recovered.token.generation, receipt.generation)
            XCTAssertEqual(recovered.token.sequence, receipt.sequence)
            XCTAssertEqual(try Data(contentsOf: freshHost.url), hostBytes)
            XCTAssertEqual(freshHost.deliveryCount, 1)
            XCTAssertEqual(try reopened.requiredObjects(in: fixture.resource.storeID, limit: 10)
                .objects.map(\.reference), [fixture.resource])
            guard case .accepted = await engine.undo() else {
                XCTFail("Recovered complete group could not Undo")
                return
            }
            XCTAssertEqual(freshHost.value, 0)
            try await reopened.close()
        }
    }

    func testRejectedOutcomesRecoverWithoutAnActionOrDuplicateDelivery() async throws {
        for point in [HistoryScopeStorage.FailurePoint.rejectionEvidence, .rejectedFinalization] {
            let fixture = try await makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            fixture.host.rejectNext = true
            let command = HistoryCommand(fingerprint: Data("rejected seven".utf8), payload: PersistenceEvidenceHost.payload(7))
            let result = await HistoryScopeStorage.$failSaveAt.withValue(point) {
                await fixture.engine.submit(command)
            }
            assertStorageFailure(result, stage: .finalization)
            XCTAssertTrue(fixture.engine.snapshot.isSuspended)
            XCTAssertEqual(try fixture.store.inspectScope(fixture.scope).pendingRecoveryCount, 1)
            let freshHost = try PersistenceEvidenceHost(directory: fixture.directory, resource: fixture.resource)
            XCTAssertEqual(freshHost.value, 0)
            XCTAssertEqual(freshHost.applicationCount, 0)
            XCTAssertEqual(freshHost.deliveryCount, 1)
            XCTAssertEqual(freshHost.receipts.map(\.command), [command.id])
            XCTAssertEqual(freshHost.receipts.map(\.accepted), [false])
            let hostBytes = try Data(contentsOf: freshHost.url)
            try await fixture.store.close()
            let reopened = try await HistoryStore.open(at: fixture.store.url,
                workingIdentity: fixture.identity, mode: .existing)
            let engine = try await reopened.openScope(fixture.scope, mode: .existing, host: freshHost)
            XCTAssertFalse(engine.snapshot.isSuspended)
            let retry = await engine.submit(command)
            XCTAssertEqual(retry, .rejected)
            XCTAssertEqual(try engine.historyPage(limit: 10).count, 0)
            XCTAssertEqual(try reopened.inspectScope(fixture.scope).pendingRecoveryCount, 0)
            XCTAssertEqual(try Data(contentsOf: freshHost.url), hostBytes)
            XCTAssertEqual(try Data(contentsOf: freshHost.resourceURL), resourceBytes)
            try await reopened.close()
        }
    }

    func testFailedDeliveryFenceNeverDeliversPreparedCommandOnReopen() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let command = HistoryCommand(fingerprint: Data("prepared seven".utf8), payload: PersistenceEvidenceHost.payload(7))
        let result = await HistoryScopeStorage.$failSaveAt.withValue(.deliveryFence) {
            await fixture.engine.submit(command)
        }
        assertStorageFailure(result, stage: .preparation)
        XCTAssertEqual(try fixture.store.inspectScope(fixture.scope).pendingRecoveryCount, 1)
        try await fixture.store.close()
        let freshHost = try PersistenceEvidenceHost(directory: fixture.directory, resource: fixture.resource)
        let reopened = try await HistoryStore.open(at: fixture.store.url, workingIdentity: fixture.identity, mode: .existing)
        let engine = try await reopened.openScope(fixture.scope, mode: .existing, host: freshHost)
        XCTAssertFalse(engine.snapshot.isSuspended)
        XCTAssertEqual(freshHost.deliveryCount, 0)
        XCTAssertEqual(freshHost.value, 0)
        XCTAssertEqual(try engine.historyPage(limit: 10).count, 0)
        let retry = await engine.submit(command)
        guard case .failure(let failure) = retry else {
            XCTFail("Cancelled preparation identity was redelivered")
            return
        }
        XCTAssertEqual(failure.cause, .busy)
        XCTAssertEqual(freshHost.deliveryCount, 0)
        try await reopened.close()
    }
    func testCopyBoundaryFailurePreservesSourceAndDoesNotOfferPartialTarget() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let command = HistoryCommand(fingerprint: Data("set seven".utf8), payload: PersistenceEvidenceHost.payload(7))
        guard case .accepted = await fixture.engine.submit(command) else {
            XCTFail("Source history failed")
            return
        }
        let sourceEntries = try fixture.engine.historyPage(limit: 10)
        let hostBytes = try Data(contentsOf: fixture.host.url)
        let destination = fixture.directory.appendingPathComponent("Failed-copy.sqlite")
        var captured = false
        do {
            try await HistoryStore.$failCopyAfterCreation.withValue(true) {
                try await fixture.store.withCoordinatedCopy(to: destination) { _ in captured = true }
            }
            XCTFail("Injected copy boundary did not fail")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .storage)
            XCTAssertEqual(failure.stage, .finalization)
            XCTAssertEqual(failure.disposition, .usable)
        }
        XCTAssertFalse(captured)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + suffix))
        }
        XCTAssertEqual(try fixture.engine.historyPage(limit: 10), sourceEntries)
        XCTAssertEqual(try Data(contentsOf: fixture.host.url), hostBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.host.resourceURL), resourceBytes)
        XCTAssertFalse(fixture.engine.snapshot.isSuspended)
        // Maintenance admission must be released even when copying fails.
        let retry = fixture.directory.appendingPathComponent("Retry.sqlite")
        try await fixture.store.copy(to: retry)
        let reader = try await HistoryStore.open(at: retry, workingIdentity: fixture.identity,
                                                 mode: .existing, access: .readOnly)
        XCTAssertEqual(try reader.historyPage(scope: fixture.scope, limit: 10), sourceEntries)
        try await reader.close()
        try await fixture.store.close()
        let freshHost = try PersistenceEvidenceHost(directory: fixture.directory, resource: fixture.resource)
        let reopened = try await HistoryStore.open(at: fixture.store.url, workingIdentity: fixture.identity, mode: .existing)
        let engine = try await reopened.openScope(fixture.scope, mode: .existing, host: freshHost)
        XCTAssertEqual(try engine.historyPage(limit: 10), sourceEntries)
        XCTAssertEqual(freshHost.applicationCount, 1)
        try await reopened.close()
    }
    func testUnavailableCodecOrResourceProtectsPendingEvidenceUntilRestored() async throws {
        for missingCodec in [true, false] {
            let fixture = try await makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let command = HistoryCommand(fingerprint: Data("set seven".utf8), payload: PersistenceEvidenceHost.payload(7))
            let result = await HistoryScopeStorage.$failSaveAt.withValue(.acceptanceEvidence) {
                await fixture.engine.submit(command)
            }
            assertStorageFailure(result, stage: .finalization)
            let hostBytes = try Data(contentsOf: fixture.host.url)
            try await fixture.store.close()
            let protectedResource = fixture.directory.appendingPathComponent("unavailable-resource.txt")
            if !missingCodec {
                try FileManager.default.moveItem(at: fixture.host.resourceURL, to: protectedResource)
            }
            let unavailableHost = try PersistenceEvidenceHost(directory: fixture.directory, resource: fixture.resource)
            unavailableHost.codecAvailable = !missingCodec
            let blocked = try await HistoryStore.open(at: fixture.store.url,
                workingIdentity: fixture.identity, mode: .existing)
            let blockedEngine = try await blocked.openScope(fixture.scope, mode: .existing, host: unavailableHost)
            XCTAssertTrue(blockedEngine.snapshot.isSuspended)
            XCTAssertEqual(try blocked.inspectScope(fixture.scope).pendingRecoveryCount, 1)
            XCTAssertEqual(try blockedEngine.historyPage(limit: 10).count, 0)
            let recovery = await blockedEngine.reconcile()
            guard case .failure(let missingPrerequisite) = recovery else {
                XCTFail("Missing interpretation prerequisite was not reported")
                return
            }
            XCTAssertEqual(missingPrerequisite.cause, .compatibility)
            XCTAssertEqual(missingPrerequisite.disposition, .suspended)
            var cleanupRan = false
            do {
                try await blocked.withRequiredObjects(in: fixture.resource.storeID) { _ in cleanupRan = true }
                XCTFail("Unresolved evidence allowed resource cleanup")
            } catch let failure as HistoryFailure {
                XCTAssertEqual(failure.cause, .unresolved)
                XCTAssertEqual(failure.disposition, .suspended)
            }
            XCTAssertFalse(cleanupRan)
            XCTAssertEqual(unavailableHost.value, 7)
            XCTAssertEqual(unavailableHost.applicationCount, 1)
            XCTAssertEqual(unavailableHost.deliveryCount, 1)
            XCTAssertEqual(try Data(contentsOf: unavailableHost.url), hostBytes)
            try await blocked.close()
            if !missingCodec {
                XCTAssertEqual(try Data(contentsOf: protectedResource), resourceBytes)
                try FileManager.default.moveItem(at: protectedResource, to: fixture.host.resourceURL)
            }
            let restoredHost = try PersistenceEvidenceHost(directory: fixture.directory, resource: fixture.resource)
            let restored = try await HistoryStore.open(at: fixture.store.url,
                workingIdentity: fixture.identity, mode: .existing)
            let restoredEngine = try await restored.openScope(fixture.scope, mode: .existing, host: restoredHost)
            XCTAssertFalse(restoredEngine.snapshot.isSuspended)
            XCTAssertEqual(try restoredEngine.historyPage(limit: 10).map(\.groupID), [command.id])
            XCTAssertEqual(try restored.requiredObjects(in: fixture.resource.storeID, limit: 10)
                .objects.map(\.reference), [fixture.resource])
            XCTAssertEqual(try Data(contentsOf: restoredHost.url), hostBytes)
            XCTAssertEqual(try Data(contentsOf: restoredHost.resourceURL), resourceBytes)
            try await restored.close()
        }
    }

    func testFailedConsolidationPreservesHistoryHoldsAndRecoveryResources() async throws {
        let fixture = try await makeFixture(limits: HistoryLimits(maxUndoGroups: 1))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var commandIDs: [UUID] = []
        for value in 1...3 {
            let command = HistoryCommand(fingerprint: Data("set \(value)".utf8), payload: PersistenceEvidenceHost.payload(value))
            guard case .accepted = await fixture.engine.submit(command) else {
                XCTFail("Retention setup failed")
                return
            }
            commandIDs.append(command.id)
        }
        let boundary = try fixture.engine.createCheckpoint(name: "Three", state: PersistenceEvidenceHost.payload(3),
                                                           resources: [fixture.resource])
        let hold = try fixture.engine.holdDetail(from: commandIDs[0], through: commandIDs[0])
        let hostBytes = try Data(contentsOf: fixture.host.url)
        do {
            _ = try HistoryScopeStorage.$failSaveAt.withValue(.retention) {
                try fixture.engine.consolidateHistory(through: boundary.id,
                    policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
            }
            XCTFail("Retention persistence failure was not returned")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .storage)
            XCTAssertEqual(failure.disposition, .suspended)
        }
        XCTAssertTrue(fixture.engine.snapshot.isSuspended)
        XCTAssertEqual(try fixture.engine.historyPage(limit: 10).map(\.groupID), commandIDs)
        XCTAssertEqual(try fixture.engine.retentionHolds().map(\.id), [hold.id])
        XCTAssertEqual(try fixture.store.requiredObjects(in: fixture.resource.storeID, limit: 10)
            .objects.map(\.referenceCount), [4])
        XCTAssertEqual(try Data(contentsOf: fixture.host.url), hostBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.host.resourceURL), resourceBytes)
        try await fixture.store.close()
        let freshHost = try PersistenceEvidenceHost(directory: fixture.directory, resource: fixture.resource)
        let reopened = try await HistoryStore.open(at: fixture.store.url, workingIdentity: fixture.identity,
                                                   mode: .existing, limits: HistoryLimits(maxUndoGroups: 1))
        let engine = try await reopened.openScope(fixture.scope, mode: .existing, host: freshHost)
        XCTAssertEqual(try engine.historyPage(limit: 10).map(\.groupID), commandIDs)
        XCTAssertEqual(try engine.retentionHolds().map(\.id), [hold.id])
        let plan = try engine.beginRecoveryPlan(to: .group(commandIDs[0]), using: .acceptedEffects)
        let protected = try engine.consolidateHistory(through: boundary.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertEqual(protected.removedGroups, 0)
        let page = try engine.recoveryPage(plan, limit: 10)
        XCTAssertEqual(page.steps.map(\.groupID), [commandIDs[2], commandIDs[1]])
        let material = try engine.recoveryMaterial(plan, groupID: commandIDs[1], ordinal: 0)
        XCTAssertEqual(material.payload, PersistenceEvidenceHost.payload(1))
        engine.releaseRecoveryPlan(plan)
        let settled = try engine.consolidateHistory(through: boundary.id,
            policy: HistoryRetentionPolicy(targetDetailedGroups: 0))
        XCTAssertEqual(settled.removedGroups, 1)
        XCTAssertEqual(try engine.historyPage(limit: 10).map(\.groupID), [commandIDs[0], commandIDs[2]])
        XCTAssertEqual(try Data(contentsOf: freshHost.url), hostBytes)
        XCTAssertEqual(try Data(contentsOf: freshHost.resourceURL), resourceBytes)
        try await reopened.close()
    }
    #endif

    func testBoundedLimitRefusalPreservesHistoryHostReceiptsAndResourceBytes() async throws {
        let fixture = try await makeFixture(limits: HistoryLimits(maxPayloadBytes: 256, maxMembers: 2))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = HistoryCommand(fingerprint: Data("set seven".utf8), payload: PersistenceEvidenceHost.payload(7))
        guard case .accepted = await fixture.engine.submit(original) else {
            XCTFail("Capacity setup failed")
            return
        }
        let hostBytes = try Data(contentsOf: fixture.host.url)
        let oversized = HistoryCommand(fingerprint: Data("oversized".utf8),
            payload: HistoryPayload(family: "persistence.set", data: Data(repeating: 49, count: 257)))
        let excessiveGroup = HistoryCommand(fingerprint: Data("too many members".utf8), members:
            (1...3).map { HistoryMember(payload: PersistenceEvidenceHost.payload($0)) })
        for command in [oversized, excessiveGroup] {
            guard case .failure(let failure) = await fixture.engine.submit(command) else {
                XCTFail("Bounded limit was not enforced")
                return
            }
            XCTAssertEqual(failure.cause, .capacity)
            XCTAssertEqual(failure.stage, .admission)
            XCTAssertEqual(failure.disposition, .usable)
        }
        XCTAssertFalse(fixture.engine.snapshot.isSuspended)
        XCTAssertTrue(fixture.engine.snapshot.canUndo)
        XCTAssertEqual(try fixture.engine.historyPage(limit: 10).map(\.groupID), [original.id])
        XCTAssertEqual(try fixture.store.requiredObjects(in: fixture.resource.storeID, limit: 10)
            .objects.map(\.reference), [fixture.resource])
        XCTAssertEqual(try Data(contentsOf: fixture.host.url), hostBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.host.resourceURL), resourceBytes)
        try await fixture.store.close()
        let freshHost = try PersistenceEvidenceHost(directory: fixture.directory, resource: fixture.resource)
        XCTAssertEqual(freshHost.value, 7)
        XCTAssertEqual(freshHost.applicationCount, 1)
        XCTAssertEqual(freshHost.deliveryCount, 1)
        XCTAssertEqual(freshHost.receipts.map(\.command), [original.id])
        let reopened = try await HistoryStore.open(at: fixture.store.url,
            workingIdentity: fixture.identity, mode: .existing)
        let engine = try await reopened.openScope(fixture.scope, mode: .existing, host: freshHost)
        XCTAssertFalse(engine.snapshot.isSuspended)
        XCTAssertEqual(try engine.historyPage(limit: 10).map(\.groupID), [original.id])
        guard case .accepted = await engine.submit(original) else {
            XCTFail("Retained accepted Command lost its receipt after capacity refusal")
            return
        }
        XCTAssertEqual(try Data(contentsOf: freshHost.url), hostBytes)
        try await reopened.close()

    }

    func testCopyRefusesExistingDestinationJournalWithoutReplacingIt() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("Occupied.sqlite")
        let sidecar = URL(fileURLWithPath: destination.path + "-wal")
        let protected = Data("preexisting journal belonging to host".utf8)
        try protected.write(to: sidecar)
        do {
            try await fixture.store.copy(to: destination)
            XCTFail("Copy replaced a preexisting destination artifact")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .identityConflict)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: sidecar), protected)
        XCTAssertEqual(try Data(contentsOf: fixture.host.resourceURL), resourceBytes)
        XCTAssertFalse(fixture.engine.snapshot.isSuspended)
        try await fixture.store.close()
    }

    private struct Fixture {
        let directory: URL
        let identity: UUID
        let scope: UUID
        let resource: HistoryObjectReference
        let store: HistoryStore
        let engine: HistoryEngine
        let host: PersistenceEvidenceHost
    }

    private func makeFixture(limits: HistoryLimits = HistoryLimits()) async throws -> Fixture {
        let directory = try testDirectory()
        let resource = HistoryObjectReference(storeID: UUID(), objectKey: "protected-resource", versionKey: "v1")
        let host = try PersistenceEvidenceHost(directory: directory, resource: resource)
        try resourceBytes.write(to: host.resourceURL)
        let identity = UUID(), scope = UUID()
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
                                                workingIdentity: identity, mode: .create, limits: limits)
        let engine = try await store.openScope(scope, mode: .create, host: host)
        return Fixture(directory: directory, identity: identity, scope: scope, resource: resource,
                       store: store, engine: engine, host: host)
    }

    private func assertStorageFailure(_ result: HistoryResult, stage: HistoryFailureStage,
                                      file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let failure) = result else {
            XCTFail("Production persistence failure was not returned", file: file, line: line)
            return
        }
        XCTAssertEqual(failure.cause, .storage, file: file, line: line)
        XCTAssertEqual(failure.stage, stage, file: file, line: line)
        XCTAssertEqual(failure.disposition, .suspended, file: file, line: line)
    }
}
