// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
@testable import UndoKit
import XCTest

@MainActor final class HistoryStoreLifecycleTests: XCTestCase {
    #if DEBUG
    func testFailedFirstRegistrationSaveLeavesCreateRetryable() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let identity = UUID()

        do {
            _ = try await HistoryStore.$failInitialRegistrationSave.withValue(true) {
                try await HistoryStore.open(at: url, workingIdentity: identity, mode: .create)
            }
            XCTFail("Injected first registration save should fail")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .storage)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))

        let created = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .create)
        let originalID = created.storeIdentity
        try await created.close()
        do {
            _ = try await HistoryStore.open(at: url, workingIdentity: UUID(), mode: .create)
            XCTFail("A successful existing store was overwritten")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .identityConflict)
        }
        let reopened = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .existing)
        XCTAssertEqual(reopened.storeIdentity, originalID)
        try await reopened.close()
    }

    #endif

    func testTwoScopesHaveIndependentOrderAndOnePhysicalOwner() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let identity = UUID(), firstScope = UUID(), secondScope = UUID()
        let store = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .create)
        let firstHost = try CounterHost(url: directory.appendingPathComponent("first.json"))
        let secondHost = try CounterHost(url: directory.appendingPathComponent("second.json"))
        let first = try await store.openScope(firstScope, mode: .create, host: firstHost)
        let second = try await store.openScope(secondScope, mode: .create, host: secondHost)

        guard case .accepted = await first.submit(HistoryCommand(fingerprint: Data("first".utf8), payload: payload(3))),
              case .accepted = await second.submit(HistoryCommand(
                  fingerprint: Data("second".utf8), payload: payload(7))) else {
            XCTFail("Both scopes should accept independent changes")
            return
        }
        XCTAssertEqual(try first.historyPage(limit: 10).map(\.sequence), [1])
        XCTAssertEqual(try second.historyPage(limit: 10).map(\.sequence), [1])
        do {
            _ = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .existing)
            XCTFail("Competing writer opened")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .busy)
        }

        try await first.close()
        XCTAssertTrue(second.snapshot.canUndo)
        guard case .accepted = await second.undo() else {
            XCTFail("Other scope stopped")
            return
        }
        try await store.close()
        let reopened = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .existing)
        let reopenedSecond = try await reopened.openScope(secondScope, mode: .existing, host: secondHost)
        XCTAssertTrue(reopenedSecond.snapshot.canRedo)
        try await reopened.close()
    }

    func testSameCommandIdentityInTwoScopesKeepsGroupsAndInversesIndependent() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
                                                workingIdentity: UUID(), mode: .create)
        let firstHost = try CounterHost(url: directory.appendingPathComponent("first.json"))
        let secondHost = try CounterHost(url: directory.appendingPathComponent("second.json"))
        let first = try await store.openScope(UUID(), mode: .create, host: firstHost)
        let second = try await store.openScope(UUID(), mode: .create, host: secondHost)
        let sharedCommand = UUID()
        let firstResult = await first.submit(HistoryCommand(id: sharedCommand,
            fingerprint: Data("first intent".utf8), payload: payload(3)))
        let secondResult = await second.submit(HistoryCommand(id: sharedCommand,
            fingerprint: Data("second intent".utf8), payload: payload(7)))
        guard case .accepted = firstResult, case .accepted = secondResult else {
            XCTFail("A command identity belongs to its scope")
            return
        }
        guard case .accepted = await second.undo() else {
            XCTFail("Second scope could not undo")
            return
        }
        XCTAssertTrue(first.snapshot.canUndo)
        XCTAssertEqual(firstHost.value, 3)
        XCTAssertEqual(secondHost.value, 0)
        guard case .accepted = await first.undo(),
              case .accepted = await second.redo(),
              case .accepted = await first.redo() else {
            XCTFail("Inverses crossed scopes")
            return
        }
        XCTAssertEqual(firstHost.value, 3)
        XCTAssertEqual(secondHost.value, 7)
        secondHost.rejectNext = true
        guard case .rejected = await second.undo() else {
            XCTFail("Second inverse was not rejected")
            return
        }
        XCTAssertTrue(first.snapshot.canUndo)
        XCTAssertFalse(second.snapshot.canUndo)
        try await store.close()
    }

    func testReadOnlyClientSurvivesWriterAndCannotMutate() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let identity = UUID(), scope = UUID()
        let writer = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .create)
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await writer.openScope(scope, mode: .create, host: host)
        guard case .accepted = await engine.submit(HistoryCommand(
            fingerprint: Data("set".utf8), payload: payload(4))) else {
            XCTFail("Writer failed")
            return
        }
        let reader = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .existing, access: .readOnly)
        XCTAssertEqual(try reader.historyPage(scope: scope, limit: 10).count, 1)
        try await writer.close()
        XCTAssertEqual(try reader.historyPage(scope: scope, limit: 10).count, 1)
        try await reader.close()
    }

    func testSameCheckpointIdentityIsIndependentAcrossScopes() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
                                                workingIdentity: UUID(), mode: .create)
        let first = try await store.openScope(UUID(), mode: .create,
            host: CounterHost(url: directory.appendingPathComponent("one.json")))
        let second = try await store.openScope(UUID(), mode: .create,
            host: CounterHost(url: directory.appendingPathComponent("two.json")))
        let checkpointID = UUID()
        _ = try first.createCheckpoint(id: checkpointID, name: "one", state: payload(1))
        _ = try second.createCheckpoint(id: checkpointID, name: "two", state: payload(2))
        XCTAssertEqual(try first.checkpoint(id: checkpointID)?.state, payload(1))
        XCTAssertEqual(try second.checkpoint(id: checkpointID)?.state, payload(2))
        try await store.close()
    }

    func testSuspendedScopeDoesNotBlockAnotherScope() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
                                                workingIdentity: UUID(), mode: .create)
        let firstHost = try CounterHost(url: directory.appendingPathComponent("one.json"))
        firstHost.loseReplyAfterSave = true
        let secondHost = try CounterHost(url: directory.appendingPathComponent("two.json"))
        let firstScope = UUID(), secondScope = UUID()
        let first = try await store.openScope(firstScope, mode: .create, host: firstHost)
        let second = try await store.openScope(secondScope, mode: .create, host: secondHost)
        guard case .failure(let failure) = await first.submit(HistoryCommand(
            fingerprint: Data("unresolved".utf8), payload: payload(1))) else {
            XCTFail("First scope should suspend")
            return
        }
        XCTAssertEqual(failure.disposition, .suspended)
        guard case .accepted = await second.submit(HistoryCommand(
            fingerprint: Data("independent".utf8), payload: payload(5))) else {
            XCTFail("Second scope should remain writable")
            return
        }
        XCTAssertTrue(first.snapshot.isSuspended)
        XCTAssertTrue(second.snapshot.canUndo)
        let reader = try await HistoryStore.open(at: store.url, workingIdentity: store.workingIdentity,
                                                 mode: .existing, access: .readOnly)
        XCTAssertEqual(try reader.inspectScope(firstScope).pendingRecoveryCount, 1)
        XCTAssertEqual(try reader.inspectScope(secondScope).pendingRecoveryCount, 0)
        try await reader.close()
        let copyURL = directory.appendingPathComponent("Unresolved-copy.sqlite")
        do {
            try await store.copy(to: copyURL)
            XCTFail("Unresolved history was copied as independently editable")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .busy)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path))
        try await store.close()
    }

    func testMissingAndCorruptHistoryHaveDistinctOpenFailures() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        do {
            _ = try await HistoryStore.open(at: url, workingIdentity: UUID(), mode: .existing)
            XCTFail("Missing history opened")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .missingHistory)
        }
        let absentParent = directory.appendingPathComponent("absent")
        do {
            _ = try await HistoryStore.open(at: absentParent.appendingPathComponent("History.sqlite"),
                                            workingIdentity: UUID(), mode: .existing, access: .readOnly)
            XCTFail("Missing read-only history opened")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .missingHistory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: absentParent.path))
        try Data("not SQLite".utf8).write(to: url)
        do {
            _ = try await HistoryStore.open(at: url, workingIdentity: UUID(), mode: .existing)
            XCTFail("Corrupt history opened")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .corruptHistory)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("not SQLite".utf8))
        let inaccessible = directory.appendingPathComponent("directory.sqlite")
        try FileManager.default.createDirectory(at: inaccessible, withIntermediateDirectories: false)
        do {
            _ = try await HistoryStore.open(at: inaccessible, workingIdentity: UUID(),
                                            mode: .existing, access: .readOnly)
            XCTFail("Directory opened as SQLite history")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .unavailableStore)
        }
    }

}

extension HistoryStoreLifecycleTests {
    func testWholeStoreCopyPreservesScopesAndGetsIndependentWorkingIdentity() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("History.sqlite")
        let copiedURL = directory.appendingPathComponent("Copy.sqlite")
        let firstScope = UUID(), secondScope = UUID(), originalID = UUID(), copiedID = UUID()
        let original = try await HistoryStore.open(at: originalURL, workingIdentity: originalID,
                                                   mode: .create)
        let first = try await original.openScope(firstScope, mode: .create,
            host: CounterHost(url: directory.appendingPathComponent("one.json")))
        let second = try await original.openScope(secondScope, mode: .create,
            host: CounterHost(url: directory.appendingPathComponent("two.json")))
        guard case .accepted = await first.submit(HistoryCommand(
            fingerprint: Data("one".utf8), payload: payload(1))),
              case .accepted = await second.submit(HistoryCommand(
            fingerprint: Data("two".utf8), payload: payload(2))) else {
            XCTFail("Preparation failed")
            return
        }
        let originalStoreID = original.storeIdentity
        try await original.withCoordinatedCopy(to: copiedURL) { _ in
            XCTAssertGreaterThan(original.physicalFootprint().temporaryMaintenanceBytes, 0)
            guard case .failure(let failure) = await first.submit(HistoryCommand(
                fingerprint: Data("late".utf8), payload: payload(3))) else {
                return XCTFail("Mutation entered during capture")
            }
            XCTAssertEqual(failure.cause, .busy)
            XCTAssertThrowsError(try second.createCheckpoint(name: "late", state: payload(3)))
            do {
                try await original.close()
                XCTFail("Store closed inside capture")
            } catch let failure as HistoryFailure {
                XCTAssertEqual(failure.cause, .busy)
            }
        }
        let copy = try await HistoryStore.open(at: copiedURL, workingIdentity: copiedID,
            mode: .independentCopy(sourceWorkingIdentity: originalID))
        XCTAssertNotEqual(copy.storeIdentity, originalStoreID)
        XCTAssertEqual(try copy.historyPage(scope: firstScope, limit: 10).count, 1)
        XCTAssertEqual(try copy.historyPage(scope: secondScope, limit: 10).count, 1)
        try await copy.close()
        try await original.close()
        let reopened = try await HistoryStore.open(at: originalURL, workingIdentity: originalID,
                                                    mode: .existing)
        XCTAssertEqual(reopened.storeIdentity, originalStoreID)
        try await reopened.close()
    }

    func testDefaultApplicationSupportPlacementIsStableAndNamespaced() throws {
        let first = try HistoryStore.applicationSupportURL(storeName: "Main", namespace: "dev.example.app")
        let second = try HistoryStore.applicationSupportURL(storeName: "Main", namespace: "dev.example.app")
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.path.contains("dev.example.app/UndoKit/Main.sqlite"))
        XCTAssertThrowsError(try HistoryStore.applicationSupportURL(storeName: "../escape", namespace: "app"))
    }

    func testStoreCloseRejectsQueuedWorkInEveryScopeAndFinishesDeliveredWork() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
                                                workingIdentity: UUID(), mode: .create)
        let firstHost = try CounterHost(url: directory.appendingPathComponent("one.json"))
        let secondHost = try CounterHost(url: directory.appendingPathComponent("two.json"))
        firstHost.pauseBeforeSave = true
        secondHost.pauseBeforeSave = true
        let first = try await store.openScope(UUID(), mode: .create, host: firstHost)
        let second = try await store.openScope(UUID(), mode: .create, host: secondHost)
        let activeFirst = Task { await first.submit(HistoryCommand(
            fingerprint: Data("one".utf8), payload: payload(1))) }
        let activeSecond = Task { await second.submit(HistoryCommand(
            fingerprint: Data("two".utf8), payload: payload(2))) }
        for _ in 0..<100 where firstHost.deliveries == 0 || secondHost.deliveries == 0 { await Task.yield() }
        let queuedFirst = Task { await first.submit(HistoryCommand(
            fingerprint: Data("late one".utf8), payload: payload(3))) }
        let queuedSecond = Task { await second.submit(HistoryCommand(
            fingerprint: Data("late two".utf8), payload: payload(4))) }
        await Task.yield()
        let close = Task { try await store.close() }
        let firstQueuedResult = await queuedFirst.value
        let secondQueuedResult = await queuedSecond.value
        firstHost.resumeDelivery()
        secondHost.resumeDelivery()
        try await close.value
        guard case .accepted = await activeFirst.value,
              case .accepted = await activeSecond.value else {
            XCTFail("Delivered work was lost")
            return
        }
        guard case .failure(let firstFailure) = firstQueuedResult,
              case .failure(let secondFailure) = secondQueuedResult else {
            XCTFail("Queued work was delivered after store closure began")
            return
        }
        XCTAssertEqual(firstFailure.stage, .admission)
        XCTAssertEqual(secondFailure.stage, .admission)
        XCTAssertEqual(firstHost.deliveries, 1)
        XCTAssertEqual(secondHost.deliveries, 1)
    }

}
