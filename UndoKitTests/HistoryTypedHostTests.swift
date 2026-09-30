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

private func versionedCodec(_ version: Int) -> HistoryCodec<DomainBox> {
    HistoryCodec(identifier: "domain.integer.v\(version)",
                 configuration: Data("format-\(version)".utf8),
                 encode: { Data("\(version):\($0.value)".utf8) },
                 decode: { data in
                     guard let text = String(bytes: data, encoding: .utf8) else {
                         throw CocoaError(.coderReadCorrupt)
                     }
                     let parts = text.split(separator: ":")
                     guard parts.count == 2, parts[0] == String(version), let value = Int(parts[1]) else {
                         throw CocoaError(.coderReadCorrupt)
                     }
                     return DomainBox(value)
                 })
}

private func versionedIdentity(_ codec: HistoryCodec<DomainBox>, version: Int) -> HistorySchemaIdentity {
    HistorySchemaIdentity(operation: "counter", commandCodec: codec.identifier,
                          effectCodec: codec.identifier, stateCodec: codec.identifier,
                          commandCodecConfiguration: codec.configuration,
                          effectCodecConfiguration: codec.configuration,
                          stateCodecConfiguration: codec.configuration,
                          commandVersion: version, effectVersion: version, stateVersion: version)
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

    func submitFourTwice(
        to engine: HistoryEngine, registration: HistoryOperationRegistration<TypedCounter>
    ) async -> (HistoryResult, HistoryResult) {
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

    func encodeStateValue(
        _ value: Int, using registration: HistoryOperationRegistration<TypedCounter>
    ) throws -> HistoryPayload {
        try encodeState(DomainBox(value), using: registration)
    }

    func decodeStateValue(_ payload: HistoryPayload,
                          using registration: HistoryOperationRegistration<TypedCounter>) throws -> Int {
        try decodeState(payload, using: registration).value
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
    func testActorReopenReadsOldHostVersionsWithoutRewritingPayloads() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("History.sqlite")
        let scope = UUID()
        let workingID = UUID()
        let oldCodec = versionedCodec(1)
        let firstHandler = TypedCounter()
        let firstRegistration = HistoryOperationRegistration(
            identity: versionedIdentity(oldCodec, version: 1), commandCodec: oldCodec,
            effectCodec: oldCodec, stateCodec: oldCodec, handler: firstHandler
        )
        let first = try await HistoryEngine.open(at: store, scope: scope, workingIdentity: workingID,
                                                 mode: .create, host: HistoryRegisteredHost(firstRegistration))
        guard case .accepted = await firstHandler.submitFour(to: first, registration: firstRegistration) else {
            XCTFail("Version 1 command was not accepted")
            return
        }
        let original = try await firstHandler.encodeStateValue(9, using: firstRegistration)
        let checkpoint = try first.createCheckpoint(name: "Old state", state: original)
        try await first.close()

        let currentCodec = versionedCodec(2)
        let incompatibleHandler = TypedCounter()
        let incompatibleRegistration = HistoryOperationRegistration(
            identity: versionedIdentity(currentCodec, version: 2), commandCodec: currentCodec,
            effectCodec: currentCodec, stateCodec: currentCodec,
            oldCommandCodecs: [1: oldCodec], oldStateCodecs: [1: oldCodec],
            handler: incompatibleHandler
        )
        let incompatible = try await HistoryEngine.open(
            at: store, scope: scope, workingIdentity: workingID, mode: .existing,
            host: HistoryRegisteredHost(incompatibleRegistration)
        )
        guard case .failure(let missingDecoder) = await incompatible.undo() else {
            XCTFail("Missing old effect decoder must refuse Undo")
            return
        }
        XCTAssertEqual(missingDecoder.cause, .compatibility)
        XCTAssertEqual(missingDecoder.disposition, .usable)
        XCTAssertTrue(incompatible.snapshot.canUndo)
        XCTAssertEqual(try incompatible.historyPage(limit: 10).count, 1)
        let valueAfterRefusedUndo = await incompatibleHandler.currentValue
        XCTAssertEqual(valueAfterRefusedUndo, 0)
        try await incompatible.close()

        let newHandler = TypedCounter()
        let registration = HistoryOperationRegistration(
            identity: versionedIdentity(currentCodec, version: 2), commandCodec: currentCodec,
            effectCodec: currentCodec, stateCodec: currentCodec,
            oldCommandCodecs: [1: oldCodec], oldEffectCodecs: [1: oldCodec],
            oldStateCodecs: [1: oldCodec], handler: newHandler
        )
        let reopened = try await HistoryEngine.open(at: store, scope: scope, workingIdentity: workingID,
                                                    mode: .existing, host: HistoryRegisteredHost(registration))
        XCTAssertEqual(try reopened.checkpoint(id: checkpoint.id)?.state, original)
        let decoded = try await newHandler.decodeStateValue(original, using: registration)
        XCTAssertEqual(decoded, 9)
        guard case .accepted = await reopened.undo() else {
            XCTFail("Old effect did not decode for Undo")
            return
        }
        let oldCommand = HistoryCommand(fingerprint: Data("old version nine".utf8), payload: original)
        guard case .accepted = await reopened.submit(oldCommand) else {
            XCTFail("Registered old Command version did not decode")
            return
        }
        let countBeforeRefusal = await newHandler.applicationCount
        let unknown = HistoryPayload(family: original.family, version: 99, data: original.data)
        let failedCommand = HistoryCommand(fingerprint: Data("unsupported".utf8), payload: unknown)
        guard case .failure(let failure) = await reopened.submit(
            failedCommand
        ) else {
            XCTFail("Unregistered Command version was not refused")
            return
        }
        XCTAssertEqual(failure.cause, .compatibility)
        let countAfterRefusal = await newHandler.applicationCount
        XCTAssertEqual(countAfterRefusal, countBeforeRefusal)
        XCTAssertEqual(try reopened.checkpoint(id: checkpoint.id)?.state, original)
        try await reopened.close()

        let retried = try await HistoryEngine.open(at: store, scope: scope, workingIdentity: workingID,
                                                  mode: .existing, host: HistoryRegisteredHost(registration))
        let repeatedResult = await retried.submit(failedCommand)
        XCTAssertEqual(repeatedResult, .failure(failure))
        let countAfterRetry = await newHandler.applicationCount
        XCTAssertEqual(countAfterRetry, countBeforeRefusal)
        try await retried.close()
    }

    func testMainActorReopenReadsOldHostVersionsAndRefusesUnknown() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("History.sqlite")
        let scope = UUID()
        let workingID = UUID()
        let oldCodec = versionedCodec(1)
        let firstHandler = MainActorTypedCounter()
        let firstRegistration = HistoryOperationRegistration(
            identity: versionedIdentity(oldCodec, version: 1), commandCodec: oldCodec,
            effectCodec: oldCodec, stateCodec: oldCodec, handler: firstHandler
        )
        let first = try await HistoryEngine.open(at: store, scope: scope, workingIdentity: workingID,
                                                 mode: .create, host: MainActorHistoryRegisteredHost(firstRegistration))
        guard case .accepted = await firstHandler.submitFour(to: first, registration: firstRegistration) else {
            XCTFail("Version 1 command was not accepted")
            return
        }
        let original = try firstHandler.encodeState(DomainBox(9), using: firstRegistration)
        let checkpoint = try first.createCheckpoint(name: "Old state", state: original)
        try await first.close()

        let currentCodec = versionedCodec(2)
        let newHandler = MainActorTypedCounter()
        let registration = HistoryOperationRegistration(
            identity: versionedIdentity(currentCodec, version: 2), commandCodec: currentCodec,
            effectCodec: currentCodec, stateCodec: currentCodec,
            oldCommandCodecs: [1: oldCodec], oldEffectCodecs: [1: oldCodec],
            oldStateCodecs: [1: oldCodec], handler: newHandler
        )
        let reopened = try await HistoryEngine.open(at: store, scope: scope, workingIdentity: workingID,
                                                    mode: .existing, host: MainActorHistoryRegisteredHost(registration))
        XCTAssertEqual(try reopened.checkpoint(id: checkpoint.id)?.state, original)
        XCTAssertEqual(try newHandler.decodeState(original, using: registration).value, 9)
        let currentState = try newHandler.encodeState(DomainBox(10), using: registration)
        XCTAssertEqual(currentState.version, 2)
        let mismatchedEnvelope = HistoryPayload(family: original.family, version: 1, data: currentState.data)
        XCTAssertThrowsError(try newHandler.decodeState(mismatchedEnvelope, using: registration))
        XCTAssertThrowsError(try newHandler.decodeState(
            HistoryPayload(family: original.family, version: 99, data: original.data), using: registration
        ))
        guard case .accepted = await reopened.undo() else {
            XCTFail("Old effect did not decode for Undo")
            return
        }
        guard case .accepted = await reopened.submit(
            HistoryCommand(fingerprint: Data("old version nine".utf8), payload: original)
        ) else {
            XCTFail("Registered old Command version did not decode")
            return
        }
        let valueBeforeRefusal = newHandler.currentValue
        let unknown = HistoryPayload(family: original.family, version: 99, data: original.data)
        guard case .failure(let failure) = await reopened.submit(
            HistoryCommand(fingerprint: Data("unsupported".utf8), payload: unknown)
        ) else {
            XCTFail("Unregistered Command version was not refused")
            return
        }
        XCTAssertEqual(failure.cause, .compatibility)
        XCTAssertEqual(newHandler.currentValue, valueBeforeRefusal)
        XCTAssertEqual(try reopened.checkpoint(id: checkpoint.id)?.state, original)
        try await reopened.close()
    }

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
            guard let value = Int(String(bytes: data, encoding: .utf8) ?? "") else {
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
        }, decode: { DomainBox(Int(String(bytes: $0, encoding: .utf8) ?? "") ?? 0) })
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
        }, decode: { DomainBox(Int(String(bytes: $0, encoding: .utf8) ?? "") ?? 0) })
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
