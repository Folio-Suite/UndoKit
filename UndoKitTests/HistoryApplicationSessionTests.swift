// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import UndoKit

@MainActor final class HistoryApplicationSessionTests: XCTestCase {

    func testTypedAtomicGroupsUndoRedoAndReopenWithoutCheckpointCodec() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let host = SessionTestHost()
        let lease = SessionTestLease()
        let operation = try sessionTestOperation(host)
        let configuration = applicationConfig(directory)
        let session = await owners.open(configuration: configuration, lease: lease, operations: [operation.erased])
        XCTAssertEqual(session.status.phase, .ready)
        let commands = try session.commands(for: operation)
        assertAccepted(await commands.submitGroup([2, 3]))
        XCTAssertEqual(try session.advanced.historyPage(limit: 10).first?.memberCount, 2)
        assertAccepted(await session.undo())
        assertAccepted(await session.redo())
        let delivered = await host.delivered()
        XCTAssertEqual(delivered, [2, 3, -3, -2, 2, 3])
        await session.close()
        XCTAssertEqual(lease.closes, 1)
        let reopened = await owners.open(
            configuration: applicationConfig(
                directory, scope: configuration.scope,
                working: configuration.workingIdentity, mode: .existing), lease: lease, operations: [operation.erased])
        XCTAssertEqual(reopened.status.phase, .ready)
        XCTAssertEqual(try reopened.advanced.historyPage(limit: 10).count, 3)
        await reopened.close()
    }

    func testIndependentScopesShareOnePhysicalStoreAndReleaseSeparately() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let host = SessionTestHost()
        let operation = try sessionTestOperation(host)
        let working = UUID()
        let firstLease = SessionTestLease()
        let secondLease = SessionTestLease()
        let first = await owners.open(
            configuration: applicationConfig(directory, working: working),
            lease: firstLease, operations: [operation.erased])
        let second = await owners.open(
            configuration: applicationConfig(directory, working: working),
            lease: secondLease, operations: [operation.erased])
        XCTAssertNotIdentical(first, second)
        XCTAssertEqual(first.status.phase, .ready)
        XCTAssertEqual(second.status.phase, .ready)
        let firstCommands = try first.commands(for: operation)
        let secondCommands = try second.commands(for: operation)
        assertAccepted(await firstCommands.submit(1))
        assertAccepted(await secondCommands.submit(2))
        await first.close()
        assertAccepted(await secondCommands.submit(3))
        XCTAssertEqual(firstLease.closes, 1)
        XCTAssertEqual(secondLease.closes, 0)
        await second.close()
        XCTAssertEqual(secondLease.closes, 1)
    }

    func testConflictingActualRegistrationCannotReplaceOrCloseLiveHost() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let lease = SessionTestLease()
        let configuration = applicationConfig(directory)
        let operation = try sessionTestOperation(SessionTestHost())
        let session = await owners.open(configuration: configuration, lease: lease, operations: [operation.erased])
        let replacement = try sessionTestOperation(SessionTestHost())
        XCTAssertThrowsError(try session.commands(for: replacement))
        let conflict = await owners.open(configuration: configuration, lease: lease, operations: [replacement.erased])
        XCTAssertEqual(conflict.status.phase, .blocked)
        XCTAssertEqual(conflict.status.issue?.cause, .identityConflict)
        await conflict.close()
        XCTAssertEqual(lease.closes, 0)
        let commands = try session.commands(for: operation)
        assertAccepted(await commands.submit(1))
        await session.close()
    }

    func testRetiredGenerationAndClosedHandlesAreExplicitlyUnexecuted() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let operation = try sessionTestOperation(SessionTestHost())
        let session = await owners.open(
            configuration: applicationConfig(directory), lease: SessionTestLease(), operations: [operation.erased])
        let old = try session.commands(for: operation)
        _ = try session.advanced.clearHistory(adopting: HistoryPayload(family: "baseline", data: Data([0])))
        guard case .unexecuted(let retired) = await old.submit(1) else { XCTFail("Retired handle executed")
return }
        XCTAssertEqual(retired.cause, .identityConflict)
        let current = try session.commands(for: operation)
        assertAccepted(await current.submit(2))
        await session.close()
        guard case .unexecuted = await current.submit(3) else { XCTFail("Closed handle executed")
return }
    }

}

extension HistoryApplicationSessionTests {
    func testCanonicalAliasesShareOwnerAndDifferentWorkingIdentityIsAnExplicitConflict() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let lease = SessionTestLease()
        let operation = try sessionTestOperation(SessionTestHost())
        let configuration = applicationConfig(directory)
        let first = await owners.open(configuration: configuration, lease: lease, operations: [operation.erased])
        let alias = HistorySessionConfiguration(
            historyURL: directory.appendingPathComponent("./History.sqlite"),
            scope: configuration.scope, workingIdentity: configuration.workingIdentity, mode: .existing)
        let same = await owners.open(configuration: alias, lease: lease, operations: [operation.erased])
        XCTAssertIdentical(first, same)
        XCTAssertEqual(lease.opens, 1)
        let original = try Data(contentsOf: configuration.historyURL)
        let conflictLease = SessionTestLease()
        let conflict = await owners.open(
            configuration: applicationConfig(directory, working: UUID()),
            lease: conflictLease, operations: [operation.erased])
        XCTAssertEqual(conflict.status.issue?.cause, .identityConflict)
        XCTAssertEqual(try Data(contentsOf: configuration.historyURL), original)
        XCTAssertEqual(conflictLease.closes, 0)
        await conflict.close()
        XCTAssertEqual(conflictLease.closes, 1)
        let commands = try first.commands(for: operation)
        assertAccepted(await commands.submit(1))
        await first.close()
    }

    func testNewScopeCanBeCreatedInExplicitlyExistingPhysicalStore() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let operation = try sessionTestOperation(SessionTestHost())
        let configuration = applicationConfig(directory)
        let first = await owners.open(
            configuration: configuration, lease: SessionTestLease(), operations: [operation.erased])
        await first.close()
        let secondConfig = HistorySessionConfiguration(
            historyURL: configuration.historyURL, scope: UUID(),
            workingIdentity: configuration.workingIdentity, mode: .existing, scopeMode: .create)
        let second = await owners.open(
            configuration: secondConfig, lease: SessionTestLease(), operations: [operation.erased])
        XCTAssertEqual(second.status.phase, .ready)
        let commands = try second.commands(for: operation)
        assertAccepted(await commands.submit(2))
        await second.close()
    }

    func testEncoderFailureIsUnexecutedAndDoesNotPreventIndependentLaterIntent() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = HistoryCodec<Int>(
            identifier: "reject-zero",
            encode: { value in
                guard value != 0 else { throw CocoaError(.coderInvalidValue) }
                return try JSONEncoder().encode(value)
            }, decode: { try JSONDecoder().decode(Int.self, from: $0) })
        let host = SessionTestHost()
        let operation = try sessionTestOperation(host, codec: codec)
        let owners = HistorySessions()
        let session = await owners.open(
            configuration: applicationConfig(directory), lease: SessionTestLease(), operations: [operation.erased])
        let commands = try session.commands(for: operation)
        guard case .unexecuted(let failure) = await commands.submit(0) else {
            XCTFail("Codec failure was ambiguous")
            return
        }
        XCTAssertEqual(failure.disposition, .usable)
        XCTAssertEqual(session.status.phase, .ready)
        assertAccepted(await commands.submit(3))
        let delivered = await host.delivered()
        XCTAssertEqual(delivered, [3])
        await session.close()
    }
}

extension HistoryApplicationSessionTests {
    #if DEBUG
    func testPreparationSaveFailureIsExplicitlyUnexecutedAndDoesNotDeliver() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let host = SessionTestHost()
        let operation = try sessionTestOperation(host)
        let session = await owners.open(
            configuration: applicationConfig(directory), lease: SessionTestLease(), operations: [operation.erased])
        let commands = try session.commands(for: operation)
        let result = await HistoryScopeStorage.$failSaveAt.withValue(.preparation) { await commands.submit(1) }
        guard case .unexecuted(let failure) = result else {
            XCTFail("Preparation failure delivery certainty lost")
            return
        }
        XCTAssertEqual(failure.stage, .preparation)
        let delivered = await host.delivered()
        XCTAssertTrue(delivered.isEmpty)
        await session.close()
    }
    #endif
}
