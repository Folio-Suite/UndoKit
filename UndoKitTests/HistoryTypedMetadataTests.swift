// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

private struct MetadataIntent: Codable, Sendable {
    let number: Int
    let origin: UUID?
}
private actor MetadataHandler: HistoryOperationHandler {
    typealias Command = MetadataIntent
    typealias Effect = Int
    let reference: HistoryObjectReference
    var outcomes: [HistoryToken: HistoryTypedOutcome<Int>] = [:]
    var observedOrigin: UUID?
    var reverse = false
    var loseReply = false
    private var applications = 0
    init(reference: HistoryObjectReference) { self.reference = reference }
    func loseNextReply() { loseReply = true }
    func reverseEvidence() { reverse = true }
    func apply(
        _ commands: [(UUID, MetadataIntent)], context: HistoryOperationContext
    ) async -> HistoryTypedOutcome<Int> {
        applications += 1
        observedOrigin = context.restorationOrigin
        let effects = commands.map {
            HistoryTypedEffect(memberID: $0.0, undo: 0, redo: $0.1.number, resources: [reference])
        }
        let result = HistoryTypedOutcome.accepted(reverse ? effects.reversed() : effects)
        outcomes[context.token] = result
        if loseReply {
            loseReply = false
            return .unresolved
        }
        return result
    }
    func undo(_ effects: [(UUID, Int)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Int> {
        .accepted(effects.map { HistoryTypedEffect(memberID: $0.0, undo: 0, redo: $0.1, resources: [reference]) })
    }
    func redo(_ effects: [(UUID, Int)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Int> {
        await undo(effects, context: context)
    }
    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<Int> { outcomes[token] ?? .unresolved }
    func origin() -> UUID? { observedOrigin }
    func applicationCount() -> Int { applications }
}
@MainActor private final class MainMetadataHandler: MainActorHistoryOperationHandler {
    typealias Command = MetadataIntent
    typealias Effect = Int
    private(set) var observedOrigin: UUID?
    func apply(
        _ commands: [(UUID, MetadataIntent)], context: HistoryOperationContext
    ) async -> HistoryTypedOutcome<Int> {
        observedOrigin = context.restorationOrigin
        return .accepted(commands.map { HistoryTypedEffect(memberID: $0.0, undo: 0, redo: $0.1.number) })
    }
    func undo(_ effects: [(UUID, Int)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Int> {
        .accepted(effects.map { HistoryTypedEffect(memberID: $0.0, undo: 0, redo: $0.1) })
    }
    func redo(_ effects: [(UUID, Int)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Int> {
        await undo(effects, context: context)
    }
    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<Int> { .unresolved }
}
@MainActor final class HistoryTypedMetadataTests: XCTestCase {
    private func operation(_ handler: MetadataHandler) throws -> HistoryOperation<MetadataIntent> {
        try HistoryOperation(
            operation: "metadata.counter", commandCodec: HistoryCodec<MetadataIntent>.json(),
            effectCodec: HistoryCodec<Int>.json(), handler: handler, fingerprint: { try JSONEncoder().encode($0) },
            metadata: {
                HistoryOperationMetadata(
                    restorationOrigin: $0.first?.origin,
                    presentation: HistoryPayload(family: "display.label", data: Data("Set value".utf8)))
            })
    }
    func testTypedMetadataAndResourcesSurviveLookupAndReopen() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = HistoryObjectReference(storeID: UUID(), objectKey: "asset", versionKey: "v2")
        let handler = MetadataHandler(reference: reference)
        let operation = try operation(handler)
        let owners = HistorySessions()
        let configuration = HistorySessionConfiguration(
            historyURL: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create)
        let session = await owners.open(
            configuration: configuration, lease: TypedTestLease(), operations: [operation.erased])
        let commands = try session.commands(for: operation)
        let origin = UUID()
        await handler.loseNextReply()
        guard case .unresolved = await commands.submit(MetadataIntent(number: 2, origin: origin)) else {
            XCTFail("Lost reply did not preserve uncertainty")
            return
        }
        guard case .accepted(let receipt) = await session.reconcile() else {
            XCTFail("Authoritative lookup failed")
            return
        }
        let seen = await handler.origin()
        XCTAssertEqual(seen, origin)
        XCTAssertEqual(try session.advanced.historyPage(limit: 10).first?.restorationOrigin, origin)
        XCTAssertEqual(try session.advanced.presentation(forGroup: receipt.groupID)?.data, Data("Set value".utf8))
        XCTAssertEqual(
            try session.advanced.requiredObjects(in: reference.storeID, limit: 10).objects.map(\.reference), [reference]
        )
        await session.close()
        let reopened = await owners.open(
            configuration: HistorySessionConfiguration(
                historyURL: configuration.historyURL,
                scope: configuration.scope, workingIdentity: configuration.workingIdentity, mode: .existing),
            lease: TypedTestLease(), operations: [operation.erased])
        XCTAssertEqual(try reopened.advanced.historyPage(limit: 10).first?.restorationOrigin, origin)
        XCTAssertEqual(try reopened.advanced.presentation(forGroup: receipt.groupID)?.data, Data("Set value".utf8))
        XCTAssertEqual(
            try reopened.advanced.requiredObjects(in: reference.storeID, limit: 10).objects.map(\.reference),
            [reference])
        let count = await handler.applicationCount()
        XCTAssertEqual(count, 1)
        await reopened.close()
    }
    func testDeclarationsRejectInvalidCurrentSchemas() throws {
        let handler = MetadataHandler(reference: HistoryObjectReference(storeID: UUID(), objectKey: "asset"))
        func invalid(
            operation: String = "metadata", commandVersion: Int = 1, effectVersion: Int = 1,
            command: HistoryCodec<MetadataIntent> = .json(), effect: HistoryCodec<Int> = .json()
        ) {
            XCTAssertThrowsError(
                try HistoryOperation(
                    operation: operation, commandVersion: commandVersion,
                    effectVersion: effectVersion, commandCodec: command, effectCodec: effect, handler: handler,
                    fingerprint: { try JSONEncoder().encode($0) })
            ) { error in
                XCTAssertEqual((error as? HistoryFailure)?.cause, .invalidInput)
                XCTAssertEqual((error as? HistoryFailure)?.stage, .admission)
            }
        }
        invalid(operation: "")
        invalid(commandVersion: 0)
        invalid(effectVersion: -1)
        invalid(command: .json(identifier: ""))
        invalid(effect: .json(identifier: ""))
    }
    func testMainActorMetadataFlowsThroughTypedOperation() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = MainMetadataHandler()
        let owners = HistorySessions()
        let origin = UUID()
        let operation = try HistoryOperation(
            operation: "main.metadata", commandCodec: HistoryCodec<MetadataIntent>.json(),
            effectCodec: HistoryCodec<Int>.json(), handler: handler, fingerprint: { try JSONEncoder().encode($0) },
            metadata: {
                HistoryOperationMetadata(
                    restorationOrigin: $0.first?.origin,
                    presentation: HistoryPayload(family: "label", data: Data("Main value".utf8)))
            })
        let session = await owners.open(
            configuration: HistorySessionConfiguration(
                historyURL: directory.appendingPathComponent("History.sqlite"),
                scope: UUID(), workingIdentity: UUID(), mode: .create), lease: TypedTestLease(),
            operations: [operation.erased])
        let commands = try session.commands(for: operation)
        guard case .accepted(let receipt) = await commands.submit(MetadataIntent(number: 3, origin: origin)) else {
            XCTFail("Main actor metadata refused")
            return
        }
        XCTAssertEqual(handler.observedOrigin, origin)
        XCTAssertEqual(try session.advanced.presentation(forGroup: receipt.groupID)?.data, Data("Main value".utf8))
        await session.close()
    }
    func testAcceptedEffectsMustMatchAtomicMemberOrder() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = MetadataHandler(reference: HistoryObjectReference(storeID: UUID(), objectKey: "asset"))
        await handler.reverseEvidence()
        let operation = try operation(handler)
        let owners = HistorySessions()
        let session = await owners.open(
            configuration: HistorySessionConfiguration(
                historyURL: directory.appendingPathComponent("History.sqlite"),
                scope: UUID(), workingIdentity: UUID(), mode: .create), lease: TypedTestLease(),
            operations: [operation.erased])
        let commands = try session.commands(for: operation)
        guard
            case .unresolved = await commands.submitGroup([
                MetadataIntent(number: 1, origin: nil), MetadataIntent(number: 2, origin: nil),
            ])
        else {
            XCTFail("Reordered accepted effects established acceptance")
            return
        }
        let count = await handler.applicationCount()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(try session.advanced.historyPage(limit: 10).isEmpty)
        await session.close()
    }
}
