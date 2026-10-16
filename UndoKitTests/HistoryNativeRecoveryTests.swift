// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import UndoKit

@MainActor final class HistoryNativeRecoveryTests: XCTestCase {
    func testUnboundDraftGatesTypedWorkUntilExplicitFieldRetryAfterReopen() async throws {
        let first = try await NativeFieldTestFixture.open()
        let (oldAttachment, adapter) = try await first.adapter()
        try adapter.change("preserved draft", composing: true)
        await first.session.close()
        let reopened = try await first.reopen()
        XCTAssertTrue(reopened.session.status.requiresDraftDecision)
        guard case .unexecuted = await reopened.commands.submit("cannot bypass") else {
            XCTFail("Unbound journal was ignored")
            return
        }
        let (attachment, recovered) = try await reopened.adapter()
        XCTAssertEqual(recovered.value, "preserved draft")
        guard case .accepted = await attachment.retryDraft() else { XCTFail("Explicit retry failed")
return }
        XCTAssertEqual(first.host.state.value, "preserved draft")
        XCTAssertEqual(first.host.state.revision, 1)
        guard case .unexecuted = await oldAttachment.commit() else {
            XCTFail("Retired attachment acted on reopened scope")
            return
        }
        attachment.disconnect()
        oldAttachment.disconnect()
        await reopened.close()
    }
    func testLostReplyReopensAndRetriesExactPreparedCommandWithoutAnotherEffect() async throws {
        let first = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await first.adapter()
        try adapter.change("accepted once")
        first.host.loseNextReply = true
        guard case .unresolved = await attachment.commit() else { XCTFail("Lost reply was not unresolved")
return }
        let original = try Data(contentsOf: first.root.appendingPathComponent("Domain.json"))
        await first.session.close()
        attachment.disconnect()
        let reopened = try await first.reopen()
        let (restored, _) = try await reopened.adapter()
        guard case .accepted = await restored.retryDraft() else { XCTFail("Exact retry did not reconcile")
return }
        XCTAssertEqual(first.host.state.revision, 1)
        XCTAssertEqual(try Data(contentsOf: first.root.appendingPathComponent("Domain.json")), original)
        restored.disconnect()
        await reopened.close()
    }
    #if DEBUG
    func testAcceptedFinalizationFailurePreservesExactFieldCommandAcrossReopen() async throws {
        let first = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await first.adapter()
        try adapter.change("accepted durable effect")
        let result = await HistoryScopeStorage.$failSaveAt.withValue(.acceptedFinalization) {
            await attachment.commit()
        }
        guard case .unresolved = result else { XCTFail("Production finalization failure was not exercised")
return }
        let original = try Data(contentsOf: first.root.appendingPathComponent("Domain.json"))
        await first.session.close()
        attachment.disconnect()
        let reopened = try await first.reopen()
        let (restored, _) = try await reopened.adapter()
        guard case .accepted = await restored.retryDraft() else { XCTFail("Prepared retry failed")
return }
        XCTAssertEqual(first.host.state.revision, 1)
        XCTAssertEqual(try Data(contentsOf: first.root.appendingPathComponent("Domain.json")), original)
        restored.disconnect()
        await reopened.close()
    }
    #endif
    func testUnknownJournalFormatIsRefusedBeforeBindingAndOriginalBytesRemain() async throws {
        let first = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await first.adapter()
        try adapter.change("draft")
        await first.session.close()
        attachment.disconnect()
        let journal = try journalURL(first)
        let bytes = Data("{\"format\":987,\"privateEvidence\":\"preserve\"}".utf8)
        try bytes.write(to: journal)
        let operation = try first.host.operation()
        let configuration = HistorySessionConfiguration(
            historyURL: first.root.appendingPathComponent("History.sqlite"),
            scope: first.host.scope, workingIdentity: first.host.working, mode: .existing)
        let refused = await first.sessions.open(
            configuration: configuration, lease: first.host, operations: [operation.erased])
        XCTAssertEqual(refused.status.phase, .blocked)
        XCTAssertEqual(try Data(contentsOf: journal), bytes)
        await refused.close()
        await first.close()
    }
    func testFailedFieldJournalWriteRetainsValuesAndPreventsHostRelease() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        let configuration = try XCTUnwrap(fixture.session.configuration)
        let directory = configuration.journalDirectory.appendingPathComponent(fixture.host.working.uuidString)
            .appendingPathComponent(fixture.host.scope.uuidString)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("7469746c65.json"), withIntermediateDirectories: true)
        try adapter.change("must survive")
        XCTAssertTrue(fixture.session.status.isEditingBlocked)
        await fixture.session.close()
        XCTAssertEqual(fixture.session.status.phase, .blocked)
        XCTAssertFalse(fixture.host.closed)
        XCTAssertEqual(adapter.value, "must survive")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("7469746c65.json"))
        await fixture.session.close()
        XCTAssertTrue(fixture.host.closed)
        attachment.disconnect()
        await fixture.close()
    }
    func testExplicitDiscardRestoresAuthoritativeValueWithoutDelivery() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("unaccepted")
        let result = await attachment.discardDraft()
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(adapter.value, "")
        XCTAssertEqual(fixture.host.state.revision, 0)
        XCTAssertEqual(adapter.retirements.count, 1)
        attachment.disconnect()
        await fixture.close()
    }
    func testDetachReleasesWeakOwnerAndRetainsDraftForNewPresentationDecision() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        var owner: NSObject? = NSObject()
        weak let weakOwner = owner
        var pair: (HistoryAttachment, NativeFieldTestAdapter)? = try await fixture.adapter(owner: owner!)
        try pair!.1.change("detached draft")
        owner = nil
        pair?.0.disconnect()
        pair = nil
        XCTAssertNil(weakOwner)
        XCTAssertTrue(fixture.session.status.requiresDraftDecision)
        let (attachment, adapter) = try await fixture.adapter()
        XCTAssertEqual(adapter.value, "detached draft")
        guard case .accepted = await attachment.retryDraft() else { XCTFail("Retained draft was not retryable")
return }
        XCTAssertEqual(fixture.host.state.value, "detached draft")
        attachment.disconnect()
        await fixture.close()
    }
    func testOversizedPreparedCommandCannotReplaceExistingCurrentJournal() async throws {
        let fixture = try await NativeFieldTestFixture.open(limits: HistoryLimits(maxPayloadBytes: 1_024))
        let field = HistoryField<String>(
            id: "bounded", mappingID: "bounded", codec: .json(), commands: fixture.commands,
            read: { try fixture.host.snapshot }, makeCommands: { _, _ in [String(repeating: "x", count: 2_048)] })
        let attachment = try fixture.session.attach(owner: NSObject())
        let adapter = NativeFieldTestAdapter(attachment: attachment, field: field.id)
        adapter.value = try await fixture.session.nativeCoordinator.register(field)
        attachment.platform = adapter
        fixture.session.nativeCoordinator.register(adapter)
        try adapter.change("small")
        let configuration = try XCTUnwrap(fixture.session.configuration)
        let journal = configuration.journalDirectory.appendingPathComponent(fixture.host.working.uuidString)
            .appendingPathComponent(fixture.host.scope.uuidString).appendingPathComponent("626f756e646564.json")
        let original = try Data(contentsOf: journal)
        guard case .unexecuted = await attachment.commit() else {
            XCTFail("Oversized preparation was not refused")
            return
        }
        XCTAssertEqual(try Data(contentsOf: journal), original)
        XCTAssertEqual(fixture.host.state.revision, 0)
        attachment.disconnect()
        await fixture.close()
    }
    func testAcceptedOrdinaryCommandCanRecoverPresentationWithoutAnotherDelivery() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        fixture.host.failReads = true
        guard case .accepted = await fixture.commands.submit("accepted ordinary command") else {
            XCTFail("Acceptance was lost")
            return
        }
        XCTAssertTrue(fixture.session.status.isEditingBlocked)
        XCTAssertEqual(adapter.value, "")
        fixture.host.failReads = false
        _ = await fixture.session.reconcile()
        XCTAssertEqual(fixture.session.status.phase, .ready)
        XCTAssertEqual(adapter.value, "accepted ordinary command")
        XCTAssertEqual(fixture.host.state.revision, 1)
        attachment.disconnect()
        await fixture.close()
    }
    private func journalURL(_ fixture: NativeFieldTestFixture) throws -> URL {
        let configuration = try XCTUnwrap(fixture.session.configuration)
        return configuration.journalDirectory.appendingPathComponent(fixture.host.working.uuidString)
            .appendingPathComponent(fixture.host.scope.uuidString).appendingPathComponent("7469746c65.json")
    }
}
