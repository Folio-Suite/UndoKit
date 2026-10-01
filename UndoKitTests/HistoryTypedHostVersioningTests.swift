// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

private struct VersionedLocation {
    let store: URL
    let scope: UUID
    let workingID: UUID
}

@MainActor extension HistoryTypedHostTests {
    func testActorReopenReadsOldHostVersionsWithoutRewritingPayloads() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("History.sqlite")
        let scope = UUID()
        let workingID = UUID()
        let oldCodec = versionedCodec(1)
        let (original, checkpoint) = try await createActorVersionOneHistory(
            store: store, scope: scope, workingID: workingID, codec: oldCodec
        )
        let currentCodec = versionedCodec(2)
        try await assertMissingActorEffectDecoder(store: store, scope: scope, workingID: workingID,
                                                  oldCodec: oldCodec, currentCodec: currentCodec)
        try await assertActorReopen(location: VersionedLocation(store: store, scope: scope, workingID: workingID),
                                    oldCodec: oldCodec, currentCodec: currentCodec,
                                    original: original, checkpoint: checkpoint)
    }

    private func createActorVersionOneHistory(
        store: URL, scope: UUID, workingID: UUID, codec oldCodec: HistoryCodec<DomainBox>
    ) async throws -> (HistoryPayload, HistoryCheckpointInfo) {
        let firstHandler = TypedCounter()
        let firstRegistration = try HistoryOperationRegistration(
            operation: "counter", commandCodec: oldCodec,
            effectCodec: oldCodec, stateCodec: oldCodec, handler: firstHandler
        )
        let first = try await HistoryEngine.open(at: store, scope: scope, workingIdentity: workingID,
                                                 mode: .create, host: HistoryRegisteredHost(firstRegistration))
        guard case .accepted = await firstHandler.submitFour(to: first, registration: firstRegistration) else {
            XCTFail("Version 1 command was not accepted")
            throw HistoryFailure(.hostProtocol, stage: .delivery, disposition: .usable)
        }
        let original = try await firstHandler.encodeStateValue(9, using: firstRegistration)
        let checkpoint = try first.createCheckpoint(name: "Old state", state: original)
        try await first.close()
        return (original, checkpoint)
    }

    private func assertMissingActorEffectDecoder(
        store: URL, scope: UUID, workingID: UUID, oldCodec: HistoryCodec<DomainBox>,
        currentCodec: HistoryCodec<DomainBox>
    ) async throws {
        let incompatibleHandler = TypedCounter()
        let incompatibleRegistration = try HistoryOperationRegistration(
            operation: "counter", commandVersion: 2, effectVersion: 2, stateVersion: 2,
            commandCodec: currentCodec,
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
    }

    private func assertActorReopen(
        location: VersionedLocation, oldCodec: HistoryCodec<DomainBox>,
        currentCodec: HistoryCodec<DomainBox>, original: HistoryPayload, checkpoint: HistoryCheckpointInfo
    ) async throws {
        let newHandler = TypedCounter()
        let registration = try HistoryOperationRegistration(
            operation: "counter", commandVersion: 2, effectVersion: 2, stateVersion: 2,
            commandCodec: currentCodec,
            effectCodec: currentCodec, stateCodec: currentCodec,
            oldCommandCodecs: [1: oldCodec], oldEffectCodecs: [1: oldCodec],
            oldStateCodecs: [1: oldCodec], handler: newHandler
        )
        let reopened = try await HistoryEngine.open(at: location.store, scope: location.scope,
                                                    workingIdentity: location.workingID,
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

        let retried = try await HistoryEngine.open(at: location.store, scope: location.scope,
                                                  workingIdentity: location.workingID,
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
        let (original, checkpoint) = try await createMainActorVersionOneHistory(
            store: store, scope: scope, workingID: workingID, codec: oldCodec
        )
        let currentCodec = versionedCodec(2)
        let newHandler = MainActorTypedCounter()
        let registration = try HistoryOperationRegistration(
            operation: "counter", commandVersion: 2, effectVersion: 2, stateVersion: 2,
            commandCodec: currentCodec,
            effectCodec: currentCodec, stateCodec: currentCodec,
            oldCommandCodecs: [1: oldCodec], oldEffectCodecs: [1: oldCodec],
            oldStateCodecs: [1: oldCodec], handler: newHandler
        )
        let reopened = try await HistoryEngine.open(at: store, scope: scope, workingIdentity: workingID,
                                                    mode: .existing, host: MainActorHistoryRegisteredHost(registration))
        XCTAssertEqual(try reopened.checkpoint(id: checkpoint.id)?.state, original)
        XCTAssertEqual(try newHandler.decodeState(original, using: registration).value, 9)
        try assertMainActorDecodeFailures(handler: newHandler, registration: registration, original: original)
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

    private func assertMainActorDecodeFailures(
        handler: MainActorTypedCounter, registration: HistoryOperationRegistration<MainActorTypedCounter>,
        original: HistoryPayload
    ) throws {
        let currentState = try handler.encodeState(DomainBox(10), using: registration)
        XCTAssertEqual(currentState.version, 2)
        let mismatchedEnvelope = HistoryPayload(family: original.family, version: 1, data: currentState.data)
        XCTAssertThrowsError(try handler.decodeState(mismatchedEnvelope, using: registration))
        XCTAssertThrowsError(try handler.decodeState(
            HistoryPayload(family: original.family, version: 99, data: original.data), using: registration
        ))
    }

    private func createMainActorVersionOneHistory(
        store: URL, scope: UUID, workingID: UUID, codec oldCodec: HistoryCodec<DomainBox>
    ) async throws -> (HistoryPayload, HistoryCheckpointInfo) {
        let firstHandler = MainActorTypedCounter()
        let firstRegistration = try HistoryOperationRegistration(
            operation: "counter", commandCodec: oldCodec,
            effectCodec: oldCodec, stateCodec: oldCodec, handler: firstHandler
        )
        let first = try await HistoryEngine.open(at: store, scope: scope, workingIdentity: workingID,
                                                 mode: .create, host: MainActorHistoryRegisteredHost(firstRegistration))
        guard case .accepted = await firstHandler.submitFour(to: first, registration: firstRegistration) else {
            XCTFail("Version 1 command was not accepted")
            throw HistoryFailure(.hostProtocol, stage: .delivery, disposition: .usable)
        }
        let original = try firstHandler.encodeState(DomainBox(9), using: firstRegistration)
        let checkpoint = try first.createCheckpoint(name: "Old state", state: original)
        try await first.close()
        return (original, checkpoint)
    }
}
