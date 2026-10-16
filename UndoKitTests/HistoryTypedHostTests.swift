// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

final class DomainBox {
    let value: Int
    init(_ value: Int) { self.value = value }
}
func versionedCodec(_ version: Int, configuration: Data? = nil) -> HistoryCodec<DomainBox> {
    HistoryCodec(
        identifier: "domain.integer.v\(version)", configuration: configuration ?? Data("format-\(version)".utf8),
        encode: { Data("\(version):\($0.value)".utf8) },
        decode: { bytes in
            guard let text = String(bytes: bytes, encoding: .utf8) else { throw CocoaError(.coderReadCorrupt) }
            let parts = text.split(separator: ":")
            guard parts.count == 2, parts[0] == String(version), let value = Int(parts[1]) else {
                throw CocoaError(.coderReadCorrupt)
            }
            return DomainBox(value)
        })
}
@MainActor final class TypedTestLease: HistoryHostLease {
    func open(_ mode: HistoryOpenMode) async throws {}
    func close() async throws {}
}

actor TypedCounter: HistoryOperationHandler {
    typealias Command = DomainBox
    typealias Effect = DomainBox
    private var value = 0
    private var receipts: [HistoryToken: HistoryTypedOutcome<DomainBox>] = [:]
    private var rejectNext = false
    private var loseNextReply = false
    private var applications = 0
    private var pauseNextApply = false
    private var paused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var deliveryWaiter: CheckedContinuation<Void, Never>?
    func rejectNextCommand() { rejectNext = true }
    func loseNextReplyAfterAcceptance() { loseNextReply = true }
    func pauseNextDelivery() { pauseNextApply = true }
    func waitUntilDeliveryPauses() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func resumeDelivery() {
        deliveryWaiter?.resume()
        deliveryWaiter = nil
    }
    func submitValue(
        _ value: Int, using commands: HistoryLocalCommands<TypedCounter>
    ) async -> HistorySubmissionResult {
        await submit(DomainBox(value), using: commands)
    }
    func apply(_ commands: [(UUID, DomainBox)], context: HistoryOperationContext) async -> HistoryTypedOutcome<
        DomainBox
    > {
        if let receipt = receipts[context.token] { return receipt }
        if pauseNextApply {
            pauseNextApply = false
            paused = true
            pauseWaiter?.resume()
            pauseWaiter = nil
            await withCheckedContinuation { deliveryWaiter = $0 }
            paused = false
        }
        applications += 1
        if rejectNext {
            rejectNext = false
            return .rejected
        }
        var effects: [HistoryTypedEffect<DomainBox>] = []
        for command in commands {
            let prior = value
            value = command.1.value
            effects.append(HistoryTypedEffect(memberID: command.0, undo: DomainBox(prior), redo: DomainBox(value)))
        }
        let result = HistoryTypedOutcome.accepted(effects)
        receipts[context.token] = result
        if loseNextReply {
            loseNextReply = false
            return .unresolved
        }
        return result
    }
    func undo(
        _ effects: [(UUID, DomainBox)], context: HistoryOperationContext
    ) async -> HistoryTypedOutcome<DomainBox> {
        await apply(effects, context: context)
    }
    func redo(
        _ effects: [(UUID, DomainBox)], context: HistoryOperationContext
    ) async -> HistoryTypedOutcome<DomainBox> {
        await apply(effects, context: context)
    }
    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<DomainBox> { receipts[token] ?? .unresolved }
    func checkpointPayload(using codec: HistoryCodec<DomainBox>) throws -> HistoryPayload {
        let bytes = try codec.encode(DomainBox(value))
        guard try codec.decode(bytes).value == value else { throw CocoaError(.coderReadCorrupt) }
        return HistoryPayload(family: "counter.state", data: bytes)
    }
    var currentValue: Int { value }
    var applicationCount: Int { applications }
}

@MainActor final class MainActorTypedCounter: MainActorHistoryOperationHandler {
    typealias Command = DomainBox
    typealias Effect = DomainBox
    private(set) var currentValue = 0
    private var receipts: [HistoryToken: HistoryTypedOutcome<DomainBox>] = [:]
    func submitValue(_ value: Int, using commands: HistoryLocalCommands<MainActorTypedCounter>) async
        -> HistorySubmissionResult {
        await submit(DomainBox(value), using: commands)
    }
    func apply(_ commands: [(UUID, DomainBox)], context: HistoryOperationContext) async -> HistoryTypedOutcome<
        DomainBox
    > {
        var effects: [HistoryTypedEffect<DomainBox>] = []
        for command in commands {
            let prior = currentValue
            currentValue = command.1.value
            effects.append(
                HistoryTypedEffect(memberID: command.0, undo: DomainBox(prior), redo: DomainBox(currentValue)))
        }
        let result = HistoryTypedOutcome.accepted(effects)
        receipts[context.token] = result
        return result
    }
    func undo(
        _ effects: [(UUID, DomainBox)], context: HistoryOperationContext
    ) async -> HistoryTypedOutcome<DomainBox> {
        await apply(effects, context: context)
    }
    func redo(
        _ effects: [(UUID, DomainBox)], context: HistoryOperationContext
    ) async -> HistoryTypedOutcome<DomainBox> {
        await apply(effects, context: context)
    }
    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<DomainBox> { receipts[token] ?? .unresolved }
}

@MainActor final class HistoryTypedHostTests: XCTestCase {
    private func operation(_ host: TypedCounter) throws -> HistoryLocalOperation<TypedCounter> {
        try HistoryLocalOperation(
            operation: "counter", commandCodec: versionedCodec(1), effectCodec: versionedCodec(1),
            handler: host, fingerprint: { Data($0.map { String($0.value) }.joined(separator: ",").utf8) })
    }
    private func open(_ directory: URL, operations: [AnyHistoryOperation]) async -> (HistorySessions, HistorySession) {
        let owners = HistorySessions()
        let session = await owners.open(
            configuration: HistorySessionConfiguration(
                historyURL: directory.appendingPathComponent("History.sqlite"),
                scope: UUID(), workingIdentity: UUID(), mode: .create), lease: TypedTestLease(), operations: operations)
        return (owners, session)
    }
    func testActorOwnedNonSendableValuesAndIndependentCheckpointCodec() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = TypedCounter()
        let operation = try operation(host)
        let (owners, session) = await open(directory, operations: [operation.erased])
        let commands = try session.localCommands(for: operation)
        guard case .accepted = await host.submitValue(4, using: commands) else {
            XCTFail("Actor-local command refused")
            return
        }
        let state = try await host.checkpointPayload(using: versionedCodec(1))
        let checkpoint = try session.advanced.createCheckpoint(name: "Four", state: state)
        XCTAssertEqual(try session.advanced.checkpoint(id: checkpoint.id)?.state, state)
        guard case .accepted = await session.undo() else { XCTFail("Undo refused")
return }
        let undone = await host.currentValue
        XCTAssertEqual(undone, 0)
        guard case .accepted = await session.redo() else { XCTFail("Redo refused")
return }
        let redone = await host.currentValue
        XCTAssertEqual(redone, 4)
        await owners.closeAll()
    }
    func testTypedRejectionAndLostReplyStayAuthoritativeWithoutResubmission() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = TypedCounter()
        let operation = try operation(host)
        let (owners, session) = await open(directory, operations: [operation.erased])
        let commands = try session.localCommands(for: operation)
        await host.rejectNextCommand()
        let rejected = await host.submitValue(1, using: commands)
        XCTAssertEqual(rejected, .rejected)
        await host.loseNextReplyAfterAcceptance()
        guard case .unresolved = await host.submitValue(2, using: commands) else {
            XCTFail("Lost reply was not unresolved")
            return
        }
        guard case .accepted = await session.reconcile() else {
            XCTFail("Exact prepared request did not reconcile")
            return
        }
        let value = await host.currentValue
        let count = await host.applicationCount
        XCTAssertEqual(value, 2)
        XCTAssertEqual(count, 2)
        await owners.closeAll()
    }
    func testMainActorHostKeepsNonSendableValuesIsolatedAndBound() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = MainActorTypedCounter()
        let operation = try HistoryLocalOperation(
            operation: "main.counter", commandCodec: versionedCodec(1), effectCodec: versionedCodec(1),
            handler: host, fingerprint: { Data($0.map { String($0.value) }.joined(separator: ",").utf8) })
        let (owners, session) = await open(directory, operations: [operation.erased])
        let commands = try session.localCommands(for: operation)
        guard case .accepted = await host.submitValue(4, using: commands) else {
            XCTFail("Main actor command refused")
            return
        }
        XCTAssertEqual(host.currentValue, 4)
        guard case .unexecuted(let failure) = await MainActorTypedCounter().submitValue(9, using: commands) else {
            XCTFail("Different main actor handler accepted")
            return
        }
        XCTAssertEqual(failure.cause, .identityConflict)
        guard case .accepted = await session.undo() else { XCTFail("Main actor Undo refused")
return }
        XCTAssertEqual(host.currentValue, 0)
        await owners.closeAll()
    }
    func testTypedQueuedCancellationDoesNotApplyCancelledCommand() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = TypedCounter()
        let operation = try operation(host)
        let (owners, session) = await open(directory, operations: [operation.erased])
        let commands = try session.localCommands(for: operation)
        await host.pauseNextDelivery()
        let first = Task { await host.submitValue(1, using: commands) }
        await host.waitUntilDeliveryPauses()
        let second = Task { await host.submitValue(2, using: commands) }
        await Task.yield()
        second.cancel()
        guard case .unexecuted(let failure) = await second.value else {
            await host.resumeDelivery()
            XCTFail("Queued cancellation ambiguous")
            return
        }
        XCTAssertEqual(failure.cause, .cancelled)
        await host.resumeDelivery()
        guard case .accepted = await first.value else { XCTFail("First request refused")
return }
        let value = await host.currentValue
        let count = await host.applicationCount
        XCTAssertEqual(value, 1)
        XCTAssertEqual(count, 1)
        await owners.closeAll()
    }
    func testActorHandleRejectsDifferentHandler() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = TypedCounter()
        let operation = try operation(host)
        let (owners, session) = await open(directory, operations: [operation.erased])
        let commands = try session.localCommands(for: operation)
        guard case .unexecuted(let failure) = await TypedCounter().submitValue(4, using: commands) else {
            XCTFail("Different actor handler accepted")
            return
        }
        XCTAssertEqual(failure.cause, .identityConflict)
        let count = await host.applicationCount
        XCTAssertEqual(count, 0)
        await owners.closeAll()
    }
}
