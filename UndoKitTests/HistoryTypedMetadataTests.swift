// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

private final class MetadataValue {
    let number: Int
    init(_ number: Int) { self.number = number }
}

private func metadataCodec(_ identifier: String = "metadata.integer") -> HistoryCodec<MetadataValue> {
    HistoryCodec(identifier: identifier, configuration: Data("decimal".utf8),
                 encode: { Data(String($0.number).utf8) },
                 decode: { data in
                     guard let text = String(bytes: data, encoding: .utf8),
                           let number = Int(text) else {
                         throw CocoaError(.coderReadCorrupt)
                     }
                     return MetadataValue(number)
                 })
}

private actor MetadataHandler: HistoryOperationHandler {
    typealias Command = MetadataValue
    typealias Effect = MetadataValue
    typealias State = MetadataValue

    private let reference: HistoryObjectReference
    private var outcomes: [UUID: HistoryTypedOutcome<MetadataValue>] = [:]
    private var observedOrigin: UUID?
    private var applications = 0
    private var reverseEffects = false

    init(reference: HistoryObjectReference) { self.reference = reference }

    func submitValue(_ number: Int, origin: UUID?, presentation: HistoryPayload?,
                     registration: HistoryOperationRegistration<MetadataHandler>,
                     to engine: any HistoryTransactions) async -> HistoryResult {
        await submit(HistoryTypedCommand(fingerprint: Data("number \(number)".utf8),
                                         value: MetadataValue(number), restorationOrigin: origin,
                                         presentation: presentation), using: registration, to: engine)
    }

    func members(using registration: HistoryOperationRegistration<MetadataHandler>) throws -> [HistoryMember] {
        [
            HistoryMember(payload: try encodeState(MetadataValue(1), using: registration)),
            HistoryMember(payload: try encodeState(MetadataValue(2), using: registration)),
        ]
    }

    func useReversedEffects() { reverseEffects = true }

    func apply(_ commands: [(UUID, MetadataValue)],
               context: HistoryOperationContext) async -> HistoryTypedOutcome<MetadataValue> {
        applications += 1
        observedOrigin = context.restorationOrigin
        let effects = commands.map {
            HistoryTypedEffect(memberID: $0.0, undo: MetadataValue(0),
                               redo: MetadataValue($0.1.number), resources: [reference])
        }
        let result = HistoryTypedOutcome<MetadataValue>.accepted(reverseEffects ? effects.reversed() : effects)
        outcomes[context.token.command] = result
        return result
    }

    func undo(_ effects: [(UUID, MetadataValue)],
              context: HistoryOperationContext) async -> HistoryTypedOutcome<MetadataValue> {
        .accepted(effects.map { HistoryTypedEffect(memberID: $0.0, undo: MetadataValue(0), redo: $0.1) })
    }

    func redo(_ effects: [(UUID, MetadataValue)],
              context: HistoryOperationContext) async -> HistoryTypedOutcome<MetadataValue> {
        .accepted(effects.map { HistoryTypedEffect(memberID: $0.0, undo: MetadataValue(0), redo: $0.1) })
    }

    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<MetadataValue> {
        outcomes[token.command] ?? .unresolved
    }

    var lastOrigin: UUID? { observedOrigin }
    var applicationCount: Int { applications }
}

@MainActor private final class MainActorMetadataHandler: MainActorHistoryOperationHandler {
    typealias Command = MetadataValue
    typealias Effect = MetadataValue
    typealias State = MetadataValue

    private let reference: HistoryObjectReference
    private var outcomes: [UUID: HistoryTypedOutcome<MetadataValue>] = [:]
    private(set) var observedOrigin: UUID?

    init(reference: HistoryObjectReference) { self.reference = reference }

    func apply(_ commands: [(UUID, MetadataValue)],
               context: HistoryOperationContext) async -> HistoryTypedOutcome<MetadataValue> {
        observedOrigin = context.restorationOrigin
        let result = HistoryTypedOutcome<MetadataValue>.accepted(commands.map {
            HistoryTypedEffect(memberID: $0.0, undo: MetadataValue(0),
                               redo: MetadataValue($0.1.number), resources: [reference])
        })
        outcomes[context.token.command] = result
        return result
    }

    func undo(_ effects: [(UUID, MetadataValue)],
              context: HistoryOperationContext) async -> HistoryTypedOutcome<MetadataValue> {
        .accepted(effects.map { HistoryTypedEffect(memberID: $0.0, undo: MetadataValue(0), redo: $0.1) })
    }

    func redo(_ effects: [(UUID, MetadataValue)],
              context: HistoryOperationContext) async -> HistoryTypedOutcome<MetadataValue> {
        .accepted(effects.map { HistoryTypedEffect(memberID: $0.0, undo: MetadataValue(0), redo: $0.1) })
    }

    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<MetadataValue> {
        outcomes[token.command] ?? .unresolved
    }
}

@MainActor final class HistoryTypedMetadataTests: XCTestCase {
    func testTypedMetadataSurvivesDeliveryLookupAndReopen() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let scope = UUID()
        let workingID = UUID()
        let storeID = UUID()
        let origin = UUID()
        let reference = HistoryObjectReference(storeID: storeID, objectKey: "asset", versionKey: "v2")
        let presentation = HistoryPayload(family: "display.label", data: Data("Set two".utf8))
        let handler = MetadataHandler(reference: reference)
        let codec = metadataCodec()
        let registration = try HistoryOperationRegistration(
            operation: "metadata-counter", commandCodec: codec, effectCodec: codec,
            stateCodec: codec, handler: handler
        )
        let host = HistoryRegisteredHost(registration)
        let engine = try await HistoryEngine.open(at: url, scope: scope, workingIdentity: workingID,
                                                   mode: .create, host: host)
        guard case .accepted(let receipt) = await handler.submitValue(2, origin: origin,
            presentation: presentation, registration: registration, to: engine) else {
            XCTFail("Typed command with metadata was not accepted")
            return
        }
        let observedOrigin = await handler.lastOrigin
        XCTAssertEqual(observedOrigin, origin)
        XCTAssertEqual(try engine.historyPage(limit: 10).first?.restorationOrigin, origin)
        XCTAssertEqual(try engine.presentation(forGroup: receipt.groupID), presentation)
        guard case .accepted(let lookedUp) = await host.outcome(for: receipt.token) else {
            XCTFail("Typed outcome lookup lost accepted effect evidence")
            return
        }
        XCTAssertEqual(lookedUp.map(\.resources), [[reference]])
        try await engine.close()

        let reopened = try await HistoryEngine.open(at: url, scope: scope, workingIdentity: workingID,
                                                     mode: .existing, host: host)
        XCTAssertEqual(try reopened.historyPage(limit: 10).first?.restorationOrigin, origin)
        XCTAssertEqual(try reopened.presentation(forGroup: receipt.groupID), presentation)
        try await reopened.close()

        let reader = try await HistoryStore.open(at: url, workingIdentity: workingID,
                                                  mode: .existing, access: .readOnly)
        XCTAssertEqual(try reader.requiredObjects(in: storeID, limit: 10).objects.map(\.reference), [reference])
        try await reader.close()
    }

    func testRegistrationDerivesCodecConfigurationAndRejectsInvalidSchemas() throws {
        let handler = MetadataHandler(reference: HistoryObjectReference(storeID: UUID(), objectKey: "asset"))
        let codec = metadataCodec()
        let registration = try HistoryOperationRegistration(
            operation: "metadata-counter", commandVersion: 2, effectVersion: 3, stateVersion: 4,
            commandCodec: codec, effectCodec: codec, stateCodec: codec, handler: handler
        )
        XCTAssertEqual(registration.identity.operation, "metadata-counter")
        XCTAssertEqual(registration.identity.commandCodec, codec.identifier)
        XCTAssertEqual(registration.identity.effectCodecConfiguration, codec.configuration)
        XCTAssertEqual(registration.identity.stateVersion, 4)

        func assertInvalid(operation: String = "metadata-counter",
                           commandVersion: Int = 1, effectVersion: Int = 1, stateVersion: Int = 1,
                           command: HistoryCodec<MetadataValue> = metadataCodec(),
                           effect: HistoryCodec<MetadataValue> = metadataCodec(),
                           state: HistoryCodec<MetadataValue> = metadataCodec(),
                           oldCommands: [Int: HistoryCodec<MetadataValue>] = [:],
                           oldEffects: [Int: HistoryCodec<MetadataValue>] = [:],
                           oldStates: [Int: HistoryCodec<MetadataValue>] = [:]) {
            XCTAssertThrowsError(try HistoryOperationRegistration(
                operation: operation, commandVersion: commandVersion, effectVersion: effectVersion,
                stateVersion: stateVersion, commandCodec: command, effectCodec: effect,
                stateCodec: state, oldCommandCodecs: oldCommands, oldEffectCodecs: oldEffects,
                oldStateCodecs: oldStates, handler: handler
            )) { error in
                guard let failure = error as? HistoryFailure else { return XCTFail("Wrong error: \(error)") }
                XCTAssertEqual(failure.cause, .invalidInput)
                XCTAssertEqual(failure.stage, .admission)
            }
        }
        assertInvalid(operation: "")
        assertInvalid(command: metadataCodec(""))
        assertInvalid(effect: metadataCodec(""))
        assertInvalid(state: metadataCodec(""))
        assertInvalid(commandVersion: 0)
        assertInvalid(effectVersion: -1)
        assertInvalid(stateVersion: 0)
        assertInvalid(commandVersion: 2, oldCommands: [0: codec])
        assertInvalid(effectVersion: 2, oldEffects: [2: codec])
        assertInvalid(stateVersion: 2, oldStates: [3: codec])
        assertInvalid(commandVersion: 2, oldCommands: [1: metadataCodec("")])
    }

    func testMainActorMetadataFlowsThroughSubmissionAndLookup() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = UUID()
        let reference = HistoryObjectReference(storeID: UUID(), objectKey: "main-actor-asset")
        let presentation = HistoryPayload(family: "display.label", data: Data("Set three".utf8))
        let handler = MainActorMetadataHandler(reference: reference)
        let codec = metadataCodec()
        let registration = try HistoryOperationRegistration(
            operation: "main-counter", commandCodec: codec, effectCodec: codec,
            stateCodec: codec, handler: handler
        )
        let host = MainActorHistoryRegisteredHost(registration)
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
                                                   scope: UUID(), workingIdentity: UUID(), mode: .create,
                                                   host: host)
        let command = HistoryTypedCommand(fingerprint: Data("number 3".utf8), value: MetadataValue(3),
                                          restorationOrigin: origin, presentation: presentation)
        guard case .accepted(let receipt) = await handler.submit(command, using: registration, to: engine) else {
            XCTFail("Main-actor typed command with metadata was not accepted")
            return
        }
        XCTAssertEqual(handler.observedOrigin, origin)
        XCTAssertEqual(try engine.historyPage(limit: 10).first?.restorationOrigin, origin)
        XCTAssertEqual(try engine.presentation(forGroup: receipt.groupID), presentation)
        guard case .accepted(let lookedUp) = await host.outcome(for: receipt.token) else {
            XCTFail("Main-actor outcome lookup lost accepted effect evidence")
            return
        }
        XCTAssertEqual(lookedUp.map(\.resources), [[reference]])
        try await engine.close()
    }

    func testAcceptedEffectsMustMatchMemberOrder() async throws {
        let reference = HistoryObjectReference(storeID: UUID(), objectKey: "asset")
        let handler = MetadataHandler(reference: reference)
        let codec = metadataCodec()
        let registration = try HistoryOperationRegistration(
            operation: "metadata-counter", commandCodec: codec, effectCodec: codec,
            stateCodec: codec, handler: handler
        )
        let members = try await handler.members(using: registration)
        await handler.useReversedEffects()
        let token = HistoryToken(scope: UUID(), generation: UUID(), sequence: 1, command: UUID())
        let delivery = HistoryDelivery(token: token, kind: .command, members: members,
                                       restorationOrigin: UUID())
        let result = await HistoryRegisteredHost(registration).deliver(delivery)
        XCTAssertEqual(result, .unresolved)
        let applicationCount = await handler.applicationCount
        XCTAssertEqual(applicationCount, 1)
    }
}
