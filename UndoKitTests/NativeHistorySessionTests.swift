// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor final class NativeHistorySessionTests: XCTestCase {
    func testDirectoryFlagDoesNotCreateAnotherOwnerForTheSameDocument() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let fileURL = URL(fileURLWithPath: directory.path, isDirectory: false)
        let first = await owners.open(documentURL: fileURL, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) {
                NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
            }
        let directoryURL = URL(fileURLWithPath: directory.path, isDirectory: true)
        let second = await owners.open(documentURL: directoryURL, mode: .existing, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) {
                NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
            }
        XCTAssertTrue(first === second)
        XCTAssertEqual(second.status.phase, .ready)
        await owners.closeAll()
    }
    func testConcurrentOpenReturnsOnlyAfterTheRetainedOwnerFinishesAcquisition() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let lease = NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        let gate = NativeDeliveryGate(); lease.openingGate = gate
        let first = Task { await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease } }
        await gate.waitUntilStarted()
        var joiningStarted = false, joiningReturned = false
        let joined = Task {
            joiningStarted = true
            let session = await owners.open(documentURL: directory, mode: .existing, codec: .json(),
                draftURL: directory.appendingPathComponent("Draft.json")) { lease }
            joiningReturned = true
            return session
        }
        while !joiningStarted { await Task.yield() }
        XCTAssertFalse(joiningReturned, "Parallel caller received an incompletely acquired owner")
        gate.resume()
        let original = await first.value, returned = await joined.value
        XCTAssertTrue(original === returned)
        XCTAssertEqual(returned.status.phase, .ready)
        await returned.close()
    }
    func testDraftCommitUndoRedoAndReopenUseIndependentDurableHost() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = UUID(), working = UUID()
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let session = await owners.open(documentURL: directory, mode: .create,
            codec: .json(), draftURL: directory.appendingPathComponent("Draft.json")) {
                NativeIntegerLease(directory: directory, scope: scope, working: working)
            }
        XCTAssertEqual(session.status.phase, .ready)
        try session.updateDraft(7)
        guard case .accepted = await session.commit() else { return XCTFail("Draft was not accepted") }
        XCTAssertEqual(try readHost(directory).value, 7)
        guard case .accepted = await session.undo() else { return XCTFail("Undo was not accepted") }
        XCTAssertEqual(try readHost(directory).value, 0)
        guard case .accepted = await session.redo() else { return XCTFail("Redo was not accepted") }
        XCTAssertEqual(try readHost(directory).value, 7)
        await session.close()
        XCTAssertEqual(session.status.phase, .closed)
        let reopened = await owners.open(documentURL: directory, mode: .existing,
            codec: .json(), draftURL: directory.appendingPathComponent("Draft.json")) {
                NativeIntegerLease(directory: directory, scope: scope, working: working)
            }
        XCTAssertTrue(reopened.status.canUndo)
        XCTAssertEqual(reopened.draft, 7)
        guard case .accepted = await reopened.undo() else { return XCTFail("Reopened Undo was not accepted") }
        XCTAssertEqual(try readHost(directory).value, 0)
        XCTAssertEqual(try readHost(directory).applicationCount, 4)
        await reopened.close()
    }
    func testMarkedDraftSurvivesClosureAndRequiresExplicitRestorationDecision() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = UUID(), working = UUID(), draftURL = directory.appendingPathComponent("Draft.json")
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(), draftURL: draftURL) {
            NativeIntegerLease(directory: directory, scope: scope, working: working)
        }
        try session.updateDraft(11, isComposing: true)
        await session.close()
        let reopened = await owners.open(documentURL: directory, mode: .existing, codec: .json(), draftURL: draftURL) {
            NativeIntegerLease(directory: directory, scope: scope, working: working)
        }
        XCTAssertEqual(reopened.draft, 11)
        XCTAssertTrue(reopened.status.requiresDraftDecision)
        XCTAssertFalse(reopened.status.canUndo)
        XCTAssertEqual(try readHost(directory).value, 0)
        guard case .accepted = await reopened.retryDraft() else { return XCTFail("Explicit restoration was not accepted") }
        XCTAssertEqual(try readHost(directory).value, 11)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
        await reopened.close()
    }

    func testIndependentSubmissionCannotOverwriteCapturedDraft() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) {
                NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
            }
        try session.updateDraft(11)
        let unrelated = HistoryCommand(fingerprint: Data("set 23".utf8), payload: PersistenceEvidenceHost.payload(23))
        guard case .failure(let failure) = await session.submit(unrelated) else { return XCTFail("Unsettled draft was overwritten") }
        XCTAssertEqual(failure.cause, .busy)
        XCTAssertEqual(session.draft, 11)
        XCTAssertEqual(try readHost(directory).value, 0)
        await session.close()
    }

    func testCloseCapturesMarkedControlValueBeforeReleasingLease() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let scope = UUID(), working = UUID(), draftURL = directory.appendingPathComponent("Draft.json")
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(), draftURL: draftURL) {
            NativeIntegerLease(directory: directory, scope: scope, working: working)
        }
        let owner = NativeIntegerPresentation(); owner.value = 17; owner.composing = true
        let connection = try session.connect(owner: owner, captureDraft: { NativeDraftCapture(value: $0.value, isComposing: $0.composing) }, draftDidChange: { _, _ in })
        await session.close(); connection.disconnect()
        let reopened = await owners.open(documentURL: directory, mode: .existing, codec: .json(), draftURL: draftURL) {
            NativeIntegerLease(directory: directory, scope: scope, working: working)
        }
        XCTAssertEqual(reopened.draft, 17)
        XCTAssertTrue(reopened.status.requiresDraftDecision)
        XCTAssertEqual(try readHost(directory).value, 0)
        _ = await reopened.discardDraft(); await reopened.close()
    }

    func testRejectedDraftUndoNeverReversesOlderAcceptedGroup() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let lease = NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        try session.updateDraft(7); _ = await session.commit()
        lease.host?.rejectNext = true
        try session.updateDraft(11)
        let refusal = await session.undo(); XCTAssertEqual(refusal, .rejected)
        XCTAssertEqual(try readHost(directory).value, 7)
        XCTAssertEqual(try readHost(directory).applicationCount, 1)
        XCTAssertEqual(session.draft, 11)
        XCTAssertTrue(session.status.requiresDraftDecision)
        _ = await session.discardDraft()
        guard case .accepted = await session.undo() else { return XCTFail("Older accepted Undo was lost") }
        XCTAssertEqual(try readHost(directory).value, 0)
        await session.close()
    }

    func testReleasingConnectionRetiresClosedOwnerAndWeakPresentation() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        var lease: NativeIntegerLease? = NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        weak let weakLease = lease
        var session: NativeHistorySession<NativeIntegerLease>? = await owners.open(documentURL: directory, mode: .create,
            codec: .json(), draftURL: directory.appendingPathComponent("Draft.json")) { lease! }
        weak let weakSession = session
        var owner: NativeIntegerPresentation? = NativeIntegerPresentation()
        weak let weakOwner = owner
        var connection: NativeHistoryConnection? = try session!.connect(owner: owner!, captureDraft: { NativeDraftCapture(value: $0.value) }, draftDidChange: { $0.value = $1 })
        owner = nil
        XCTAssertNil(weakOwner, "Session retained its native presenter")
        await session!.close()
        XCTAssertEqual(owners.entries.count, 1)
        XCTAssertNotNil(connection)
        connection = nil
        XCTAssertTrue(owners.entries.isEmpty, "Abandoned connection retained a closed recovery owner")
        session = nil; lease = nil
        XCTAssertNil(weakSession)
        XCTAssertNil(weakLease)
    }

    func testNativeUndoClosesAdmissionImmediatelyAndCloseDrainsCompositeOperation() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let lease = NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        let owner = NativeIntegerPresentation(); owner.value = 13
        let connection = try session.connect(owner: owner, captureDraft: { NativeDraftCapture(value: $0.value) }, draftDidChange: { _, _ in })
        let gate = NativeDeliveryGate(); lease.deliveryGate = gate
        session.undoManager.undo()
        XCTAssertEqual(session.status.phase, .busy, "Native admission must close before a Task starts")
        XCTAssertFalse(session.undoManager.canUndo)
        let refusal = await session.submit(HistoryCommand(fingerprint: Data("other".utf8), payload: PersistenceEvidenceHost.payload(23)))
        guard case .failure(let failure) = refusal else { return XCTFail("Independent operation was queued") }
        XCTAssertEqual(failure.cause, .busy)
        await gate.waitUntilStarted()
        let closure = Task { await session.close() }
        await Task.yield()
        XCTAssertTrue(session.status.isEditingBlocked)
        XCTAssertEqual(try readHost(directory).value, 0)
        gate.resume(); await closure.value
        XCTAssertEqual(session.status.phase, .closed)
        XCTAssertEqual(try readHost(directory).value, 0)
        XCTAssertEqual(try readHost(directory).applicationCount, 2)
        connection.disconnect()
    }

    func testCloseDuringOpeningWaitsForAcquisitionBeforeCompleteLeaseClosure() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let lease = NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        let gate = NativeDeliveryGate(); lease.openingGate = gate
        let opening = Task { await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease } }
        await gate.waitUntilStarted()
        let retained = try XCTUnwrap(owners.session(for: directory))
        let closure = Task { await retained.close() }
        await Task.yield()
        XCTAssertEqual(retained.status.phase, .closing)
        XCTAssertNotNil(lease.history, "Opening lease released before acquisition settled")
        XCTAssertEqual(owners.entries.count, 1)
        gate.resume(); _ = await opening.value; await closure.value
        XCTAssertEqual(retained.status.phase, .closed)
        XCTAssertNil(lease.history)
        XCTAssertTrue(owners.entries.isEmpty)
        await retained.close()
    }

    func testFailedDraftPersistenceCannotCertifyLeaseClosureOrLoseCapturedValue() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = HistoryCodec<Int>(identifier: "failing-codec", encode: {
            if $0 == 17 { throw CocoaError(.fileWriteNoPermission) }
            return try JSONEncoder().encode($0)
        }, decode: { try JSONDecoder().decode(Int.self, from: $0) })
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let lease = NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        let session = await owners.open(documentURL: directory, mode: .create, codec: codec,
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        XCTAssertThrowsError(try session.updateDraft(17))
        await session.close()
        XCTAssertEqual(session.status.phase, .blocked)
        XCTAssertEqual(session.draft, 17)
        XCTAssertEqual(owners.entries.count, 1)
        XCTAssertNotNil(lease.history, "Unsaved captured value lost its recovery lease")
        _ = await session.discardDraft(); await session.close()
        XCTAssertTrue(owners.entries.isEmpty)
    }

    func testExplicitCommitCapturesCurrentConnectedControlValue() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) {
                NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
            }
        let owner = NativeIntegerPresentation()
        let connection = try session.connect(owner: owner, captureDraft: { NativeDraftCapture(value: $0.value) }, draftDidChange: { $0.value = $1 })
        owner.value = 9
        guard case .accepted = await session.commit() else { return XCTFail("Current control value was not captured") }
        XCTAssertEqual(try readHost(directory).value, 9)
        await session.close(); connection.disconnect()
    }

    func testUncertainAcceptedDraftReopensAndRetriesExactCommandWithoutDuplicateEffect() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = UUID(), working = UUID(), draftURL = directory.appendingPathComponent("Draft.json")
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let lease = NativeIntegerLease(directory: directory, scope: scope, working: working)
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(), draftURL: draftURL) { lease }
        lease.host?.hideOutcome = true
        try session.updateDraft(19)
        guard case .failure = await session.commit() else { return XCTFail("Uncertain outcome was not suspended") }
        let accepted = try readHost(directory)
        XCTAssertEqual(accepted.value, 19)
        XCTAssertEqual(accepted.applicationCount, 1)
        let originalCommand = try XCTUnwrap(accepted.receipts.first?.command)
        let originalBytes = try Data(contentsOf: accepted.url)
        await session.close()
        let reopened = await owners.open(documentURL: directory, mode: .existing, codec: .json(), draftURL: draftURL) {
            NativeIntegerLease(directory: directory, scope: scope, working: working)
        }
        XCTAssertTrue(reopened.status.requiresDraftDecision)
        XCTAssertEqual(reopened.draft, 19)
        guard case .accepted(let receipt) = await reopened.retryDraft() else { return XCTFail("Exact uncertain Command was not resolved") }
        XCTAssertEqual(receipt.token.command, originalCommand)
        XCTAssertEqual(try Data(contentsOf: accepted.url), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
        await reopened.close()
    }

    #if DEBUG
    func testDurableAcceptanceFailedFinalizationRetriesExactPreparedCommand() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) {
                NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
            }
        try session.updateDraft(31)
        guard case .failure(let failure) = await session.demonstrateFinalizationFailure() else { return XCTFail("Production finalization save did not fail") }
        XCTAssertEqual(failure.stage, .finalization)
        XCTAssertEqual(session.status.phase, .suspended)
        let accepted = try readHost(directory)
        let originalCommand = try XCTUnwrap(accepted.receipts.first?.command)
        let originalBytes = try Data(contentsOf: accepted.url)
        guard case .accepted(let receipt) = await session.retryDraft() else { return XCTFail("Finalization did not reconcile") }
        XCTAssertEqual(receipt.token.command, originalCommand)
        XCTAssertEqual(try Data(contentsOf: accepted.url), originalBytes)
        XCTAssertEqual(session.draft, 31)
        XCTAssertTrue(session.status.canUndo)
        await session.close()
    }
    #endif

    func testMismatchedJournalRefusesDiscardAndPreservesOriginalEvidence() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = UUID(), working = UUID(), draftURL = directory.appendingPathComponent("Draft.json")
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(), draftURL: draftURL) {
            NativeIntegerLease(directory: directory, scope: scope, working: working)
        }
        try session.updateDraft(29); await session.close()
        let original = try Data(contentsOf: draftURL)
        let incompatible = await owners.open(documentURL: directory, mode: .existing, codec: .json(), codecVersion: 2, draftURL: draftURL) {
            NativeIntegerLease(directory: directory, scope: scope, working: working)
        }
        XCTAssertEqual(incompatible.status.phase, .blocked)
        XCTAssertEqual(incompatible.status.issue?.cause, .compatibility)
        guard case .failure = await incompatible.discardDraft() else { return XCTFail("Uninterpretable draft was discarded") }
        XCTAssertEqual(try Data(contentsOf: draftURL), original)
        await incompatible.close()
        XCTAssertEqual(try Data(contentsOf: draftURL), original)
        let compatible = await owners.open(documentURL: directory, mode: .existing, codec: .json(), draftURL: draftURL) {
            NativeIntegerLease(directory: directory, scope: scope, working: working)
        }
        XCTAssertEqual(compatible.draft, 29)
        guard case .accepted = await compatible.retryDraft() else { return XCTFail("Preserved draft could not be restored") }
        XCTAssertEqual(try readHost(directory).value, 29)
        await compatible.close()
    }

    func testPartiallyClosedLeaseStaysOwnedAndExplicitRetryRestoresUsableSession() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let lease = NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        try session.updateDraft(7)
        lease.failAfterEngineClose = true
        await session.close()
        XCTAssertEqual(session.status.phase, .blocked)
        let same = await owners.open(documentURL: directory, mode: .existing, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) {
                XCTFail("Factory ran while incomplete closure remained owned")
                return NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
            }
        XCTAssertTrue(same === session)
        lease.failAfterEngineClose = false
        guard case .accepted = await session.retryDraft() else { return XCTFail("Explicit retry reused a partially closed engine") }
        XCTAssertEqual(try readHost(directory).value, 7)
        await session.close()
        XCTAssertTrue(owners.entries.isEmpty)
    }

    func testRetiredOwnerAndConnectionCannotReopenOrRemoveReplacement() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let scope = UUID(), working = UUID(), draftURL = directory.appendingPathComponent("Draft.json")
        let original = await owners.open(documentURL: directory, mode: .create, codec: .json(), draftURL: draftURL) {
            NativeIntegerLease(directory: directory, scope: scope, working: working)
        }
        let firstOwner = NativeIntegerPresentation()
        let retiredConnection = try original.connect(owner: firstOwner,
            captureDraft: { NativeDraftCapture(value: $0.value) }, draftDidChange: { $0.value = $1 })
        firstOwner.value = 5; _ = await original.commit()
        await original.close(); retiredConnection.disconnect()
        let replacement = await owners.open(documentURL: directory, mode: .existing, codec: .json(), draftURL: draftURL) {
            NativeIntegerLease(directory: directory, scope: scope, working: working)
        }
        let nextOwner = NativeIntegerPresentation()
        let currentConnection = try replacement.connect(owner: nextOwner,
            captureDraft: { NativeDraftCapture(value: $0.value) }, draftDidChange: { $0.value = $1 })
        await owners.reopen(original)
        await original.close(); retiredConnection.disconnect(); original.undoManager.undo()
        XCTAssertEqual(original.status.phase, .closed)
        XCTAssertTrue(owners.session(for: directory) === replacement)
        XCTAssertEqual(replacement.status.phase, .ready)
        XCTAssertTrue(replacement.hasConnection)
        XCTAssertTrue(replacement.status.canUndo)
        guard case .accepted = await replacement.undo() else { return XCTFail("Retired attachment disturbed replacement history") }
        XCTAssertEqual(try readHost(directory).value, 0)
        await replacement.close(); currentConnection.disconnect()
    }

    func testUnexplainedNativeRegistrationBlocksUnrelatedAcceptanceAndPreservesNativeWork() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) {
                NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
            }
        var target: NativeIntegerPresentation? = NativeIntegerPresentation()
        weak let weakTarget = target
        let selectorTarget = NativeSelectorUndoTarget()
        session.undoManager.groupsByEvent = false
        session.undoManager.beginUndoGrouping()
        session.undoManager.registerUndo(withTarget: selectorTarget,
            selector: #selector(NativeSelectorUndoTarget.restore(_:)), object: target!)
        session.undoManager.endUndoGrouping()
        target = nil
        let unrelated = HistoryCommand(fingerprint: Data("set 23".utf8), payload: PersistenceEvidenceHost.payload(23))
        let result = await session.submit(unrelated)
        if case .accepted = result { XCTFail("Unrelated acceptance silently erased unexplained native work") }
        XCTAssertNotNil(weakTarget)
        XCTAssertTrue(session.status.isEditingBlocked)
        XCTAssertFalse(session.undoManager.canUndo)
        XCTAssertEqual(try readHost(directory).value, 0)
        await session.close()
        XCTAssertNotEqual(session.status.phase, .closed, "Complete close discarded unidentified native work")
        XCTAssertNotNil(weakTarget)
        try await session.reconcileNativeRegistrations()
        XCTAssertNil(weakTarget)
        XCTAssertEqual(session.status.phase, .ready)
        await session.close()
    }

    func testDisconnectCapturesMarkedControlBeforeReleasingPresentation() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let scope = UUID(), working = UUID(), draftURL = directory.appendingPathComponent("Draft.json")
        let original = await owners.open(documentURL: directory, mode: .create, codec: .json(), draftURL: draftURL) {
            NativeIntegerLease(directory: directory, scope: scope, working: working)
        }
        let owner = NativeIntegerPresentation()
        let connection = try original.connect(owner: owner,
            captureDraft: { NativeDraftCapture(value: $0.value, isComposing: $0.composing) }, draftDidChange: { $0.value = $1 })
        owner.value = 22; owner.composing = true
        connection.disconnect()
        XCTAssertFalse(original.hasConnection)
        XCTAssertEqual(original.draft, 22)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path))
        await original.close()
        let reopened = await owners.open(documentURL: directory, mode: .existing, codec: .json(), draftURL: draftURL) {
            NativeIntegerLease(directory: directory, scope: scope, working: working)
        }
        XCTAssertEqual(reopened.draft, 22)
        XCTAssertTrue(reopened.status.requiresDraftDecision)
        XCTAssertEqual(try readHost(directory).value, 0)
        _ = await reopened.discardDraft(); await reopened.close()
    }

    func testFailedAuthoritativeRefreshPreservesPreparedDraftAndStopsCompositeUndo() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let lease = NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        let draftURL = directory.appendingPathComponent("Draft.json")
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(), draftURL: draftURL) { lease }
        try session.updateDraft(13)
        lease.failReadAfterAcceptance = true
        guard case .failure = await session.undo() else { return XCTFail("Composite Undo continued after authoritative refresh failed") }
        XCTAssertEqual(session.status.phase, .blocked)
        XCTAssertEqual(try readHost(directory).value, 13)
        XCTAssertEqual(try readHost(directory).applicationCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path))
        lease.failReadAfterAcceptance = false
        guard case .accepted = await session.retryDraft() else { return XCTFail("Prepared accepted intent could not recover") }
        XCTAssertEqual(try readHost(directory).applicationCount, 1)
        guard case .accepted = await session.undo() else { return XCTFail("Recovered accepted group cannot Undo") }
        XCTAssertEqual(try readHost(directory).value, 0)
        await session.close()
    }

    func testHostDeclaredSemanticNoopRestoresAuthoritativeDraftAndClearsProvisionalUndo() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let lease = NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        let draftURL = directory.appendingPathComponent("Draft.json")
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(), draftURL: draftURL) { lease }
        // The host declares this proposal semantically equivalent to its existing domain state.
        lease.semanticNoop = 23
        try session.updateDraft(23)
        let result = await session.commit()
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(session.draft, 0)
        XCTAssertFalse(session.status.canUndo)
        XCTAssertFalse(session.undoManager.canUndo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
        XCTAssertEqual(try readHost(directory).applicationCount, 0)
        await session.close()
    }

    func testUnknownRegistrationArrivingDuringDrainBlocksCloseAndPreservesWork() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let lease = NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        let gate = NativeDeliveryGate(); lease.deliveryGate = gate
        try session.updateDraft(7)
        let submitting = Task { await session.commit() }
        await gate.waitUntilStarted()
        let closing = Task { await session.close() }
        await Task.yield()
        var object: NativeIntegerPresentation? = NativeIntegerPresentation()
        weak let preserved = object
        let target = NativeSelectorUndoTarget()
        session.undoManager.groupsByEvent = false
        session.undoManager.beginUndoGrouping()
        session.undoManager.registerUndo(withTarget: target,
            selector: #selector(NativeSelectorUndoTarget.restore(_:)), object: object!)
        session.undoManager.endUndoGrouping(); object = nil
        gate.resume(); _ = await submitting.value; await closing.value
        XCTAssertNotEqual(session.status.phase, .closed)
        XCTAssertTrue(session.status.isEditingBlocked)
        XCTAssertNotNil(preserved)
        XCTAssertNotNil(lease.history, "Drain-time unknown work released the domain lease")
        XCTAssertTrue(owners.session(for: directory) === session)
        try await session.reconcileNativeRegistrations()
        XCTAssertNil(preserved)
        await session.close()
        XCTAssertTrue(owners.entries.isEmpty)
    }

    func testUnknownRegistrationArrivingDuringCompleteLeaseCloseRetainsOwnerAndReacquiresForRecovery() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let lease = NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        let draftURL = directory.appendingPathComponent("Draft.json")
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(), draftURL: draftURL) { lease }
        var presenter: NativeIntegerPresentation? = NativeIntegerPresentation()
        weak let preserved = presenter
        let connection = try session.connect(owner: presenter!, captureDraft: { NativeDraftCapture(value: $0.value) }, draftDidChange: { $0.value = $1 })
        let gate = NativeDeliveryGate(); lease.completeCloseGate = gate
        let closing = Task { await session.close() }
        await gate.waitUntilStarted()
        XCTAssertNil(lease.history, "Fixture must have completely released its history before closure returns")
        presenter!.value = 17
        let target = NativeSelectorUndoTarget()
        session.undoManager.groupsByEvent = false
        session.undoManager.beginUndoGrouping()
        session.undoManager.registerUndo(withTarget: target,
            selector: #selector(NativeSelectorUndoTarget.restore(_:)), object: presenter!)
        session.undoManager.endUndoGrouping(); presenter = nil
        gate.resume(); await closing.value
        XCTAssertEqual(session.status.phase, .blocked)
        XCTAssertNotNil(preserved)
        XCTAssertTrue(owners.session(for: directory) === session)
        let same = await owners.open(documentURL: directory, mode: .existing, codec: .json(), draftURL: draftURL) {
            XCTFail("A second factory bypassed blocked closure ownership")
            return NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        }
        XCTAssertTrue(same === session)
        try await session.reconcileNativeRegistrations()
        XCTAssertNotNil(lease.history, "Recovery released callback data before reacquiring its document lease")
        XCTAssertNil(preserved)
        XCTAssertEqual(session.draft, 17)
        guard case .accepted = await session.retryDraft() else { return XCTFail("Preserved authored values could not commit after recovery") }
        XCTAssertEqual(try readHost(directory).value, 17)
        await session.close(); connection.disconnect()
        XCTAssertTrue(owners.entries.isEmpty)
    }

    func testBlockedRefreshCanReconcileNativeWorkWithoutReplacingPreparedCommand() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let lease = NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        let draftURL = directory.appendingPathComponent("Draft.json")
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(), draftURL: draftURL) { lease }
        try session.updateDraft(13); lease.failReadAfterAcceptance = true
        guard case .accepted = await session.commit() else { return XCTFail("Authoritative transaction was not accepted") }
        XCTAssertEqual(session.status.phase, .blocked)
        let originalCommand = try XCTUnwrap(try readHost(directory).receipts.first?.command)
        var object: NativeIntegerPresentation? = NativeIntegerPresentation()
        weak let preserved = object
        let target = NativeSelectorUndoTarget()
        session.undoManager.groupsByEvent = false
        session.undoManager.beginUndoGrouping()
        session.undoManager.registerUndo(withTarget: target,
            selector: #selector(NativeSelectorUndoTarget.restore(_:)), object: object!)
        session.undoManager.endUndoGrouping(); object = nil
        lease.failReadAfterAcceptance = false
        try await session.reconcileNativeRegistrations()
        XCTAssertNil(preserved)
        XCTAssertEqual(session.draft, 13)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftURL.path))
        guard case .accepted(let receipt) = await session.retryDraft() else { return XCTFail("Blocked exact intent did not recover") }
        XCTAssertEqual(receipt.token.command, originalCommand)
        XCTAssertEqual(try readHost(directory).applicationCount, 1)
        XCTAssertEqual(session.status.phase, .ready)
        await session.close()
    }

    func testNativeReconciliationPreservesExplicitDraftDecisionAfterRejectionAndRestore() async throws {
        for restore in [false, true] {
            let directory = try testDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let owners = NativeHistorySessions<NativeIntegerLease>()
            let scope = UUID(), working = UUID(), draftURL = directory.appendingPathComponent("Draft.json")
            let lease = NativeIntegerLease(directory: directory, scope: scope, working: working)
            var session = await owners.open(documentURL: directory, mode: .create, codec: .json(), draftURL: draftURL) { lease }
            try session.updateDraft(13, isComposing: restore)
            if restore {
                await session.close()
                session = await owners.open(documentURL: directory, mode: .existing, codec: .json(), draftURL: draftURL) {
                    NativeIntegerLease(directory: directory, scope: scope, working: working)
                }
            } else {
                lease.host?.rejectNext = true
                let rejection = await session.commit(); XCTAssertEqual(rejection, .rejected)
            }
            XCTAssertTrue(session.status.requiresDraftDecision)
            var object: NativeIntegerPresentation? = NativeIntegerPresentation()
            weak let preserved = object
            let target = NativeSelectorUndoTarget()
            session.undoManager.groupsByEvent = false
            session.undoManager.beginUndoGrouping()
            session.undoManager.registerUndo(withTarget: target,
                selector: #selector(NativeSelectorUndoTarget.restore(_:)), object: object!)
            session.undoManager.endUndoGrouping(); object = nil
            try await session.reconcileNativeRegistrations()
            XCTAssertNil(preserved)
            XCTAssertEqual(session.draft, 13)
            XCTAssertTrue(session.status.requiresDraftDecision, "Native reconciliation implicitly chose draft restoration")
            XCTAssertFalse(session.status.canUndo)
            XCTAssertEqual(try readHost(directory).applicationCount, 0)
            guard case .accepted = await session.retryDraft() else { return XCTFail("Explicit draft decision could not recover") }
            XCTAssertFalse(session.status.requiresDraftDecision)
            XCTAssertEqual(try readHost(directory).value, 13)
            XCTAssertEqual(try readHost(directory).applicationCount, 1)
            await session.close()
        }
    }

    func testCloseWaitsForAwaitedNativeReconciliationToFinish() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = NativeHistorySessions<NativeIntegerLease>()
        let lease = NativeIntegerLease(directory: directory, scope: UUID(), working: UUID())
        let session = await owners.open(documentURL: directory, mode: .create, codec: .json(),
            draftURL: directory.appendingPathComponent("Draft.json")) { lease }
        try session.updateDraft(7); lease.failAfterEngineClose = true
        await session.close(); lease.failAfterEngineClose = false
        let gate = NativeDeliveryGate(); lease.openingGate = gate
        let reconciliation = Task { try await session.reconcileNativeRegistrations() }
        await gate.waitUntilStarted()
        let completed = expectation(description: "Close drains native reconciliation")
        let closing = Task { await session.close(); completed.fulfill() }
        await Task.yield()
        XCTAssertEqual(session.status.phase, .closing)
        gate.resume(); try await reconciliation.value
        let outcome = await XCTWaiter.fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(outcome, .completed, "Reconciliation failed to wake complete-close waiters")
        if outcome == .completed { await closing.value }
        XCTAssertEqual(session.status.phase, .closed)
        XCTAssertTrue(owners.entries.isEmpty)
    }

    private func readHost(_ directory: URL) throws -> PersistenceEvidenceHost {
        try PersistenceEvidenceHost(directory: directory, resource: NativeIntegerLease.resource)
    }
}

@MainActor private final class NativeIntegerLease: NativeHistoryLease, HistoryHost {
    static let resource = HistoryObjectReference(storeID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, objectKey: "resource")
    let directory: URL
    let scope: UUID
    let working: UUID
    var history: HistoryEngine?
    var host: PersistenceEvidenceHost?
    var deliveryGate: NativeDeliveryGate?
    var openingGate: NativeDeliveryGate?
    var completeCloseGate: NativeDeliveryGate?
    var failClose = false
    var failAfterEngineClose = false
    var failReadAfterAcceptance = false
    var semanticNoop: Int?
    init(directory: URL, scope: UUID, working: UUID) {
        self.directory = directory; self.scope = scope; self.working = working
    }
    func open(_ mode: NativeHistoryOpenMode) async throws {
        if mode == .create { try Data("resource".utf8).write(to: directory.appendingPathComponent("retained-resource.txt")) }
        let host = try PersistenceEvidenceHost(directory: directory, resource: Self.resource)
        self.host = host
        history = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
            scope: scope, workingIdentity: working, mode: mode == .create ? .create : .existing, host: self)
        if let openingGate { await openingGate.pause() }
    }
    func close() async throws {
        if failClose { throw CocoaError(.fileWriteNoPermission) }
        try await history?.close()
        if failAfterEngineClose { throw CocoaError(.fileWriteNoPermission) }
        history = nil; host = nil
        if let completeCloseGate { await completeCloseGate.pause() }
    }
    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        if let deliveryGate { await deliveryGate.pause() }
        return await host!.deliver(delivery)
    }
    func outcome(for token: HistoryToken) async -> HistoryHostOutcome { await host!.outcome(for: token) }
    func readDraft() async throws -> NativeDraftSnapshot<Int> {
        let host = try XCTUnwrap(host)
        if failReadAfterAcceptance && host.applicationCount > 0 { throw CocoaError(.fileReadNoPermission) }
        return NativeDraftSnapshot(value: host.value, revision: Data(String(host.applicationCount).utf8))
    }
    func makeCommand(from base: NativeDraftSnapshot<Int>, to proposed: Int, generation: UUID) async throws -> HistoryCommand? {
        guard proposed != base.value, proposed != semanticNoop else { return nil }
        return HistoryCommand(fingerprint: Data("set \(proposed)".utf8),
            payload: PersistenceEvidenceHost.payload(proposed), expectedGeneration: generation)
    }
}

@MainActor private final class NativeIntegerPresentation { var value = 0; var composing = false }

@MainActor private final class NativeDeliveryGate {
    var paused: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    var released = false
    func pause() async {
        guard !released else { return }
        await withCheckedContinuation { paused = $0; started?.resume(); started = nil }
    }
    func waitUntilStarted() async {
        if paused != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resume() { released = true; paused?.resume(); paused = nil }
}

@MainActor private final class NativeSelectorUndoTarget: NSObject {
    @objc func restore(_ object: AnyObject) {}
}
