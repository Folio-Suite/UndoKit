// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

/// Current codecs are explicit. Unsupported retained versions/configurations fail without legacy readers.
@MainActor final class HistoryTypedHostVersioningTests: XCTestCase {
    private func operation(
        _ handler: TypedCounter, version: Int,
        configuration: Data? = nil
    ) throws -> HistoryLocalOperation<TypedCounter> {
        try HistoryLocalOperation(
            operation: "current.counter", commandVersion: version, effectVersion: version,
            commandCodec: versionedCodec(version, configuration: configuration),
            effectCodec: versionedCodec(version, configuration: configuration), handler: handler,
            fingerprint: { Data($0.map { String($0.value) }.joined(separator: ",").utf8) })
    }
    func testReopenedCurrentCodecRetainsTypedUndoAndOriginalCheckpointBytes() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = TypedCounter()
        let operation = try operation(host, version: 2)
        let owners = HistorySessions()
        let configuration = HistorySessionConfiguration(
            historyURL: directory.appendingPathComponent("History.sqlite"), scope: UUID(), workingIdentity: UUID(),
            mode: .create)
        let first = await owners.open(
            configuration: configuration, lease: TypedTestLease(), operations: [operation.erased])
        let commands = try first.localCommands(for: operation)
        guard case .accepted = await host.submitValue(4, using: commands) else {
            XCTFail("Current typed command refused")
            return
        }
        let state = try await host.checkpointPayload(using: versionedCodec(2))
        let checkpoint = try first.advanced.createCheckpoint(name: "Current", state: state)
        await first.close()
        let rebuilt = try self.operation(host, version: 2)
        let reopened = await owners.open(
            configuration: HistorySessionConfiguration(
                historyURL: configuration.historyURL,
                scope: configuration.scope, workingIdentity: configuration.workingIdentity, mode: .existing),
            lease: TypedTestLease(), operations: [rebuilt.erased])
        XCTAssertEqual(try reopened.advanced.checkpoint(id: checkpoint.id)?.state, state)
        guard case .accepted = await reopened.undo() else {
            XCTFail("Current effect could not decode on reopen")
            return
        }
        let value = await host.currentValue
        XCTAssertEqual(value, 0)
        await reopened.close()
    }
    func testUnknownRetainedEffectVersionRefusesDeliveryAndPreservesHistory() async throws {
        try await refusedReopen(version: 2, configuration: nil)
    }
    func testChangedCurrentCodecConfigurationRefusesDeliveryAndPreservesHistory() async throws {
        try await refusedReopen(version: 1, configuration: Data("different-format".utf8))
    }
    private func refusedReopen(version: Int, configuration changed: Data?) async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = TypedCounter()
        let firstOperation = try operation(host, version: 1)
        let owners = HistorySessions()
        let configuration = HistorySessionConfiguration(
            historyURL: directory.appendingPathComponent("History.sqlite"), scope: UUID(), workingIdentity: UUID(),
            mode: .create)
        let first = await owners.open(
            configuration: configuration, lease: TypedTestLease(), operations: [firstOperation.erased])
        let commands = try first.localCommands(for: firstOperation)
        guard case .accepted = await host.submitValue(4, using: commands) else {
            XCTFail("Initial command refused")
            return
        }
        let original = try first.advanced.historyPage(limit: 10)
        await first.close()
        let incompatible = try operation(host, version: version, configuration: changed)
        let reopened = await owners.open(
            configuration: HistorySessionConfiguration(
                historyURL: configuration.historyURL,
                scope: configuration.scope, workingIdentity: configuration.workingIdentity, mode: .existing),
            lease: TypedTestLease(), operations: [incompatible.erased])
        guard case .failed(let failure) = await reopened.undo() else {
            XCTFail("Unsupported codec was silently accepted")
            return
        }
        XCTAssertEqual(failure.cause, .compatibility)
        XCTAssertEqual(try reopened.advanced.historyPage(limit: 10), original)
        let count = await host.applicationCount
        XCTAssertEqual(count, 1)
        await reopened.close()
    }
}
