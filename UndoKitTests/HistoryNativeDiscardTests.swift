// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import UndoKit

@MainActor final class HistoryNativeDiscardTests: XCTestCase {
    func testCheckpointCannotMutateHistoryDuringDiscardAuthoritativeRead() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("draft to discard")
        let gate = NativeFieldReadGate()
        fixture.host.fieldReadGate = gate
        let engine = try XCTUnwrap(fixture.session.engine)
        let discard = Task { await attachment.discardDraft() }
        await gate.waitUntilStarted()
        XCTAssertThrowsError(try engine.createCheckpoint(name: "during discard", state: payload(1))) { error in
            XCTAssertEqual((error as? HistoryFailure)?.cause, .busy)
        }
        gate.resume()
        let result = await discard.value
        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(try engine.checkpoints(limit: 10).isEmpty)
        fixture.host.fieldReadGate = nil
        _ = try engine.createCheckpoint(name: "after discard", state: payload(1))
        attachment.disconnect()
        await fixture.close()
    }

    func testCancelledDiscardKeepsExclusionUntilThrowingHostReadCompletes() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("preserved draft")
        let gate = NativeFieldReadGate()
        fixture.host.fieldReadGate = gate
        let engine = try XCTUnwrap(fixture.session.engine)
        let original = try Data(contentsOf: fixture.root.appendingPathComponent("Domain.json"))
        let discard = Task { await attachment.discardDraft() }
        await gate.waitUntilStarted()
        discard.cancel()
        let reconciliation = await fixture.session.reconcile()
        guard case .unexecuted(let reconciliationFailure)? = reconciliation else {
            XCTFail("Reconciliation during active discard was not explicitly unexecuted")
            return
        }
        XCTAssertEqual(reconciliationFailure.cause, .busy)
        let submit = await fixture.commands.submit("must not enter")
        guard case .unexecuted(let failure) = submit else {
            XCTFail("Cancelled active discard lost exclusion")
            return
        }
        XCTAssertEqual(failure.cause, .busy)
        XCTAssertThrowsError(try engine.createCheckpoint(name: nil, state: payload(1)))
        fixture.host.failReads = true
        gate.resume()
        guard case .unexecuted = await discard.value else {
            XCTFail("Throwing field read succeeded")
            return
        }
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("Domain.json")), original)
        fixture.host.failReads = false
        fixture.host.fieldReadGate = nil
        let retried = await attachment.discardDraft()
        XCTAssertEqual(retried, .rejected)
        _ = try engine.createCheckpoint(name: "after read failure", state: payload(1))
        attachment.disconnect()
        await fixture.close()
    }

    func testCloseWaitsForDiscardAuthoritativeReadBeforeReleasingDomainLease() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("discarded before closure")
        let gate = NativeFieldReadGate()
        fixture.host.fieldReadGate = gate
        let engine = try XCTUnwrap(fixture.session.engine)
        let discard = Task { await attachment.discardDraft() }
        await gate.waitUntilStarted()
        XCTAssertEqual(fixture.session.status.phase, .busy)
        XCTAssertTrue(engine.transaction.reconciling)
        let close = Task { await fixture.session.close() }
        while fixture.session.status.phase != .closing { await Task.yield() }
        XCTAssertFalse(fixture.host.closed)
        XCTAssertFalse(engine.transaction.closed)
        gate.resume()
        let result = await discard.value
        await close.value
        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(fixture.host.closed)
        XCTAssertEqual(fixture.session.status.phase, .closed)
        XCTAssertEqual(fixture.host.state.revision, 0)
        attachment.disconnect()
        await fixture.close()
    }

    func testRetryCannotChangeRejectedPreparedIntentWhileDiscardReadIsSuspended() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("rejected draft")
        fixture.host.rejectNext = true
        let rejection = await attachment.commit()
        XCTAssertEqual(rejection, .rejected)
        let transaction = try XCTUnwrap(fixture.session.nativeCoordinator.transaction)
        let state = try XCTUnwrap(fixture.session.nativeCoordinator.fields[fixture.field.id])
        let prepared = try XCTUnwrap(state.prepared)
        let journal = try Data(contentsOf: state.journalURL)
        let receipts = try Data(contentsOf: fixture.root.appendingPathComponent("Domain.json"))
        let gate = NativeFieldReadGate()
        fixture.host.fieldReadGate = gate
        let discard = Task { await attachment.discardDraft() }
        await gate.waitUntilStarted()
        let retry = await attachment.retryDraft()
        guard case .unexecuted(let failure) = retry else {
            XCTFail("Retry entered an active discard")
            gate.resume()
            _ = await discard.value
            return
        }
        XCTAssertEqual(failure.cause, .busy)
        XCTAssertEqual(fixture.session.nativeCoordinator.transaction?.id, transaction.id)
        XCTAssertEqual(state.prepared?.id, prepared.id)
        XCTAssertTrue(state.requiresDecision)
        XCTAssertEqual(try Data(contentsOf: state.journalURL), journal)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("Domain.json")), receipts)
        gate.resume()
        let discarded = await discard.value
        XCTAssertEqual(discarded, .rejected)
        XCTAssertEqual(adapter.value, "")
        XCTAssertEqual(fixture.host.state.revision, 0)
        XCTAssertEqual(fixture.host.state.receipts.count, 1)
        fixture.host.fieldReadGate = nil
        attachment.disconnect()
        await fixture.close()
    }

    func testDiscardHostReadCannotReenterRetryOrCloseItsOwnActivity() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("discarded")
        let engine = try XCTUnwrap(fixture.session.engine)
        fixture.host.fieldReadAction = {
            await fixture.session.close()
            XCTAssertFalse(fixture.host.closed)
            let retry = await fixture.session.retryDraft()
            guard case .unexecuted(let failure) = retry else {
                XCTFail("Read callback reentered its own discard")
                return
            }
            XCTAssertEqual(failure.cause, .busy)
            do {
                try await engine.store.close()
                XCTFail("Read callback closed its own history store")
            } catch let failure as HistoryFailure { XCTAssertEqual(failure.cause, .busy) } catch {
                XCTFail("Unexpected store close failure: \(error)")
            }
        }
        let result = await attachment.discardDraft()
        fixture.host.fieldReadAction = nil
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(fixture.session.status.phase, .ready)
        XCTAssertFalse(fixture.host.closed)
        XCTAssertFalse(engine.store.closed)
        XCTAssertEqual(fixture.host.state.revision, 0)
        attachment.disconnect()
        await fixture.close()
    }
    func testClosingDuringCoreReconciliationPreservesReceiptAndSkipsPresentationRefresh() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, _) = try await fixture.adapter()
        fixture.host.loseNextReply = true
        let submitted = await fixture.commands.submit("accepted once")
        guard case .unresolved = submitted else {
            XCTFail("Lost reply was not exercised")
            return
        }
        let original = try Data(contentsOf: fixture.root.appendingPathComponent("Domain.json"))
        let gate = NativeFieldReadGate()
        fixture.host.outcomeGate = gate
        var presentationReads = 0
        fixture.host.fieldReadAction = { presentationReads += 1 }
        let recovery = Task { await fixture.session.reconcile() }
        await gate.waitUntilStarted()
        let closing = Task { await fixture.session.close() }
        while fixture.session.status.phase != .closing { await Task.yield() }
        XCTAssertFalse(fixture.host.closed)
        gate.resume()
        let result = await recovery.value
        await closing.value
        guard case .accepted = result else {
            XCTFail("Accepted reconciliation receipt was lost")
            return
        }
        XCTAssertEqual(presentationReads, 0)
        XCTAssertTrue(fixture.host.closed)
        XCTAssertEqual(fixture.session.status.phase, .closed)
        XCTAssertEqual(fixture.host.state.revision, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("Domain.json")), original)
        fixture.host.fieldReadAction = nil
        fixture.host.outcomeGate = nil
        attachment.disconnect()
        await fixture.close()
    }
}
