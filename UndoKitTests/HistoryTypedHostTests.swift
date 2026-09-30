// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

private final class DomainBox {
    let value: Int
    init(_ value: Int) { self.value = value }
}

private struct DomainCodecs {
    let command: HistoryCodec<DomainBox>
    let effect: HistoryCodec<DomainBox>
    let state: HistoryCodec<DomainBox>
}

private actor TypedCounter: HistoryOperationHandler {
    typealias Command = DomainBox
    typealias Effect = DomainBox
    typealias State = DomainBox

    private var value = 0
    private var receipts: [UUID: HistoryTypedOutcome<DomainBox>] = [:]
    private var rejectNext = false
    private var loseNextReply = false
    private var applications = 0
    private var pauseNextApply = false
    private var paused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var deliveryWaiter: CheckedContinuation<Void, Never>?

    func submitFour(to engine: HistoryEngine,
                    registration: HistoryOperationRegistration<TypedCounter>) async -> HistoryResult {
        await submit(HistoryTypedCommand(fingerprint: Data("set four".utf8), value: DomainBox(4)),
                     using: registration, to: engine)
    }

    func submitFourTwice(to engine: HistoryEngine,
                         registration: HistoryOperationRegistration<TypedCounter>) async -> (HistoryResult, HistoryResult) {
        let command = HistoryTypedCommand(id: UUID(), fingerprint: Data("set four".utf8), value: DomainBox(4))
        let first = await submit(command, using: registration, to: engine)
        let retry = await submit(command, using: registration, to: engine)
        return (first, retry)
    }

    func submit(_ command: HistoryTypedCommand<DomainBox>, to engine: HistoryEngine,
                registration: HistoryOperationRegistration<TypedCounter>) async -> HistoryResult {
        await submit(command, using: registration, to: engine)
    }

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
    func submitValue(_ value: Int, to engine: HistoryEngine,
                     registration: HistoryOperationRegistration<TypedCounter>) async -> HistoryResult {
        let command = HistoryTypedCommand(fingerprint: Data("set \(value)".utf8), value: DomainBox(value))
        return await submit(command, using: registration, to: engine)
    }

    func stateRoundTrip(using registration: HistoryOperationRegistration<TypedCounter>) throws -> Int {
        let payload = try encodeState(DomainBox(9), using: registration)
        return try decodeState(payload, using: registration).value
    }

    func apply(_ commands: [(UUID, DomainBox)], token: HistoryToken) async -> HistoryTypedOutcome<DomainBox> {
        if let receipt = receipts[token.command] { return receipt }
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
        let prior = value
        value = commands.last?.1.value ?? value
        let effects = commands.map {
            HistoryTypedEffect(memberID: $0.0, undo: DomainBox(prior), redo: DomainBox(value))
        }
        let result = HistoryTypedOutcome<DomainBox>.accepted(effects)
        receipts[token.command] = result
        if loseNextReply {
            loseNextReply = false
            return .unresolved
        }
        return result
    }

    func undo(_ effects: [(UUID, DomainBox)], token: HistoryToken) async -> HistoryTypedOutcome<DomainBox> {
        let prior = value
        value = effects.first?.1.value ?? value
        return .accepted(effects.map {
            HistoryTypedEffect(memberID: $0.0, undo: DomainBox(prior), redo: DomainBox(value))
        })
    }

    func redo(_ effects: [(UUID, DomainBox)], token: HistoryToken) async -> HistoryTypedOutcome<DomainBox> {
        let prior = value
        value = effects.first?.1.value ?? value
        return .accepted(effects.map {
            HistoryTypedEffect(memberID: $0.0, undo: DomainBox(prior), redo: DomainBox(value))
        })
    }

    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<DomainBox> {
        receipts[token.command] ?? .unresolved
    }

    var currentValue: Int { value }
    var applicationCount: Int { applications }
}

@MainActor private final class MainActorTypedCounter: MainActorHistoryOperationHandler {
    typealias Command = DomainBox
    typealias Effect = DomainBox
    typealias State = DomainBox
    private var value = 0
    private var receipts: [UUID: HistoryTypedOutcome<DomainBox>] = [:]

    func submitFour(to engine: HistoryEngine,
                    registration: HistoryOperationRegistration<MainActorTypedCounter>) async -> HistoryResult {
        await submit(HistoryTypedCommand(fingerprint: Data("set four".utf8), value: DomainBox(4)),
                     using: registration, to: engine)
    }

    func apply(_ commands: [(UUID, DomainBox)], token: HistoryToken) async -> HistoryTypedOutcome<DomainBox> {
        let prior = value
        value = commands.last?.1.value ?? value
        let result = HistoryTypedOutcome<DomainBox>.accepted(commands.map {
            HistoryTypedEffect(memberID: $0.0, undo: DomainBox(prior), redo: DomainBox(value))
        })
        receipts[token.command] = result
        return result
    }

    func undo(_ effects: [(UUID, DomainBox)], token: HistoryToken) async -> HistoryTypedOutcome<DomainBox> {
        let prior = value
        value = effects.first?.1.value ?? value
        return .accepted(effects.map {
            HistoryTypedEffect(memberID: $0.0, undo: DomainBox(prior), redo: DomainBox(value))
        })
    }

    func redo(_ effects: [(UUID, DomainBox)], token: HistoryToken) async -> HistoryTypedOutcome<DomainBox> {
        let prior = value
        value = effects.first?.1.value ?? value
        return .accepted(effects.map {
            HistoryTypedEffect(memberID: $0.0, undo: DomainBox(prior), redo: DomainBox(value))
        })
    }

    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<DomainBox> {
        receipts[token.command] ?? .unresolved
    }

    var currentValue: Int { value }
}

@MainActor final class HistoryTypedHostTests: XCTestCase {
    func testActorOwnedNonSendableValuesRetryAndRoundTripState() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = TypedCounter()
        let codec = HistoryCodec<DomainBox>(identifier: "domain.integer.v1", encode: {
            var value = Int64($0.value).bigEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }, decode: { data in
            guard data.count == MemoryLayout<Int64>.size else { throw CocoaError(.coderReadCorrupt) }
            let bits = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return DomainBox(Int(Int64(bitPattern: bits)))
        })
        let codecs = DomainCodecs(command: codec, effect: codec, state: codec)
        let identity = HistorySchemaIdentity(operation: "counter", commandCodec: codec.identifier,
                                             effectCodec: codec.identifier, stateCodec: codec.identifier)
        let registration = HistoryOperationRegistration(identity: identity, commandCodec: codec,
                                                        effectCodec: codec, stateCodec: codec, handler: handler)
        let host = HistoryRegisteredHost(registration)
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
                                                   scope: UUID(), workingIdentity: UUID(), mode: .create,
                                                   host: host)
        let pair = await handler.submitFourTwice(to: engine, registration: registration)
        guard case .accepted = pair.0, case .accepted = pair.1 else {
            XCTFail("Original command and duplicate retry must return the same accepted receipt")
            return
        }
        let currentValue = await handler.currentValue
        let stateValue = try await handler.stateRoundTrip(using: registration)
        XCTAssertEqual(currentValue, 4)
        XCTAssertEqual(stateValue, 9)
        XCTAssertEqual(codecs.state.identifier, identity.stateCodec)
        try await engine.close()
    }

    func testTypedRejectionAndLostReplyStayAuthoritative() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = TypedCounter()
        let codec = HistoryCodec<DomainBox>(identifier: "domain.integer.v1", encode: {
            Data(String($0.value).utf8)
        }, decode: { data in
            guard let value = Int(String(decoding: data, as: UTF8.self)) else {
                throw CocoaError(.coderReadCorrupt)
            }
            return DomainBox(value)
        })
        let identity = HistorySchemaIdentity(operation: "counter", commandCodec: codec.identifier,
                                             effectCodec: codec.identifier, stateCodec: codec.identifier)
        let registration = HistoryOperationRegistration(identity: identity, commandCodec: codec,
                                                        effectCodec: codec, stateCodec: codec, handler: handler)
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
                                                   scope: UUID(), workingIdentity: UUID(), mode: .create,
                                                   host: HistoryRegisteredHost(registration))
        await handler.rejectNextCommand()
        let rejected = await handler.submitValue(6, to: engine, registration: registration)
        XCTAssertEqual(rejected, .rejected)
        await handler.loseNextReplyAfterAcceptance()
        guard case .failure(let failure) = await handler.submitValue(8, to: engine, registration: registration) else {
            XCTFail("Lost host reply must leave an unresolved transaction")
            return
        }
        XCTAssertEqual(failure.disposition, .suspended)
        XCTAssertTrue(engine.snapshot.isSuspended)
        let currentValue = await handler.currentValue
        XCTAssertEqual(currentValue, 8)
        try await engine.close()
    }

    func testMainActorHostKeepsNonSendableValuesIsolated() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = HistoryCodec<DomainBox>(identifier: "domain.integer.v1", encode: {
            Data(String($0.value).utf8)
        }, decode: { DomainBox(Int(String(decoding: $0, as: UTF8.self)) ?? 0) })
        let handler = MainActorTypedCounter()
        let identity = HistorySchemaIdentity(operation: "counter", commandCodec: codec.identifier,
                                             effectCodec: codec.identifier, stateCodec: codec.identifier)
        let registration = HistoryOperationRegistration(identity: identity, commandCodec: codec,
                                                        effectCodec: codec, stateCodec: codec, handler: handler)
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
                                                   scope: UUID(), workingIdentity: UUID(), mode: .create,
                                                   host: MainActorHistoryRegisteredHost(registration))
        guard case .accepted = await handler.submitFour(to: engine, registration: registration) else {
            XCTFail("MainActor typed command was not accepted")
            return
        }
        XCTAssertEqual(handler.currentValue, 4)
        try await engine.close()
    }

    func testTypedQueuedCancellationDoesNotApplyCancelledCommand() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = HistoryCodec<DomainBox>(identifier: "domain.integer.v1", encode: {
            Data(String($0.value).utf8)
        }, decode: { DomainBox(Int(String(decoding: $0, as: UTF8.self)) ?? 0) })
        let handler = TypedCounter()
        let identity = HistorySchemaIdentity(operation: "counter", commandCodec: codec.identifier,
                                             effectCodec: codec.identifier, stateCodec: codec.identifier)
        let registration = HistoryOperationRegistration(identity: identity, commandCodec: codec,
                                                        effectCodec: codec, stateCodec: codec, handler: handler)
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
                                                   scope: UUID(), workingIdentity: UUID(), mode: .create,
                                                   host: HistoryRegisteredHost(registration))
        await handler.pauseNextDelivery()
        let first = Task { await handler.submitValue(10, to: engine, registration: registration) }
        await handler.waitUntilDeliveryPauses()
        let cancelled = Task { await handler.submitValue(11, to: engine, registration: registration) }
        cancelled.cancel()
        guard case .failure(let failure) = await cancelled.value else {
            XCTFail("Cancelled queued command was not refused")
            return
        }
        XCTAssertEqual(failure.cause, .cancelled)
        await handler.resumeDelivery()
        guard case .accepted = await first.value else {
            XCTFail("First command did not complete")
            return
        }
        let currentValue = await handler.currentValue
        let applicationCount = await handler.applicationCount
        XCTAssertEqual(currentValue, 10)
        XCTAssertEqual(applicationCount, 1)
        try await engine.close()
    }
}
