// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor final class HistoryStoreLifecycleTests: XCTestCase {
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
              case .accepted = await second.submit(HistoryCommand(fingerprint: Data("second".utf8), payload: payload(7))) else {
            return XCTFail("Both scopes should accept independent changes")
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
        guard case .accepted = await second.undo() else { return XCTFail("Other scope stopped") }
        try await store.close()
        let reopened = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .existing)
        let reopenedSecond = try await reopened.openScope(secondScope, mode: .existing, host: secondHost)
        XCTAssertTrue(reopenedSecond.snapshot.canRedo)
        try await reopened.close()
    }

    func testReadOnlyClientSurvivesWriterAndCannotMutate() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let identity = UUID(), scope = UUID()
        let writer = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .create)
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await writer.openScope(scope, mode: .create, host: host)
        guard case .accepted = await engine.submit(HistoryCommand(fingerprint: Data("set".utf8), payload: payload(4))) else {
            return XCTFail("Writer failed")
        }
        let reader = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .existing, access: .readOnly)
        XCTAssertEqual(try reader.historyPage(scope: scope, limit: 10).count, 1)
        try await writer.close()
        XCTAssertEqual(try reader.historyPage(scope: scope, limit: 10).count, 1)
        try await reader.close()
    }
}
