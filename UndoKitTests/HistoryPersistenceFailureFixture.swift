// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
@testable import UndoKit
import XCTest

extension HistoryPersistenceFailureTests {
    var resourceBytes: Data { Data("Required recovery resource v1".utf8) }

    struct Fixture {
        let directory: URL
        let identity: UUID
        let scope: UUID
        let resource: HistoryObjectReference
        let store: HistoryStore
        let engine: HistoryEngine
        let host: PersistenceEvidenceHost
    }

    func makeFixture(limits: HistoryLimits = HistoryLimits()) async throws -> Fixture {
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

    func assertStorageFailure(_ result: HistoryResult, stage: HistoryFailureStage,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let failure) = result else {
            XCTFail("Production persistence failure was not returned", file: file, line: line)
            return
        }
        XCTAssertEqual(failure.cause, .storage, file: file, line: line)
        XCTAssertEqual(failure.stage, stage, file: file, line: line)
        XCTAssertEqual(failure.disposition, .suspended, file: file, line: line)
    }
    #if DEBUG
    func assertAcceptedEvidence(_ host: PersistenceEvidenceHost, command: HistoryCommand,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(host.value, 7, file: file, line: line)
        XCTAssertEqual(host.applicationCount, 1, file: file, line: line)
        XCTAssertEqual(host.receipts.first?.command, command.id, file: file, line: line)
        XCTAssertEqual(host.receipts.first?.effects.map(\.member), command.members.map(\.id), file: file, line: line)
        XCTAssertEqual(host.receipts.first?.effects.map(\.before), [0, 4], file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: host.resourceURL), resourceBytes, file: file, line: line)
    }

    func assertMissingPrerequisite(_ result: HistoryResult?,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let failure) = result else {
            XCTFail("Missing interpretation prerequisite was not reported", file: file, line: line)
            return
        }
        XCTAssertEqual(failure.cause, .compatibility, file: file, line: line)
        XCTAssertEqual(failure.disposition, .suspended, file: file, line: line)
    }

    func assertCleanupRefused(in blocked: HistoryStore, retentionStore: UUID) async throws {
        var cleanupRan = false
        do {
            try await blocked.withRequiredObjects(in: retentionStore) { _ in cleanupRan = true }
            XCTFail("Unresolved evidence allowed resource cleanup")
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, .unresolved)
            XCTAssertEqual(failure.disposition, .suspended)
        }
        XCTAssertFalse(cleanupRan)
    }

    func populateRetentionFixture(_ fixture: Fixture) async throws -> [UUID] {
        var commandIDs: [UUID] = []
        for value in 1...3 {
            let command = HistoryCommand(fingerprint: Data("set \(value)".utf8),
                payload: PersistenceEvidenceHost.payload(value))
            guard case .accepted = await fixture.engine.submit(command) else {
                throw RetentionFixtureFailure.command
            }
            commandIDs.append(command.id)
        }
        return commandIDs
    }

    private enum RetentionFixtureFailure: Error { case command }
    #endif
}
