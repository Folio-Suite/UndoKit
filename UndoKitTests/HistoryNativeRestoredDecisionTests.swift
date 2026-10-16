// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import UndoKit

@MainActor final class HistoryNativeRestoredDecisionTests: XCTestCase {
    func testRestoredRejectionBlocksNewEditingInversesAndOrdinaryCommitUntilExplicitRetry() async throws {
        let first = try await NativeFieldTestFixture.open()
        let (original, editor) = try await first.adapter()
        try editor.change("Rejected")
        first.host.rejectNext = true
        let rejected = await original.commit()
        XCTAssertEqual(rejected, .rejected)
        await first.session.close()
        original.disconnect()
        let reopened = try await first.reopen()
        let (attachment, adapter) = try await reopened.adapter()
        let state = try XCTUnwrap(reopened.session.nativeCoordinator.fields[reopened.field.id])
        let journal = try Data(contentsOf: state.journalURL)
        let commandID = state.prepared?.id
        XCTAssertTrue(state.rejected)
        XCTAssertTrue(reopened.session.status.requiresDraftDecision)
        XCTAssertFalse(reopened.session.nativeCoordinator.canRetryLiveRejection)
        XCTAssertFalse(
            reopened.session.nativeCoordinator.permitsEditing(
                attachment: attachment.id, control: adapter.control, composing: false))
        XCTAssertFalse(
            reopened.session.nativeCoordinator.beginChange(
                attachment: attachment.id, control: adapter.control, field: reopened.field.id, composing: false))
        XCTAssertFalse(reopened.session.nativeCoordinator.requestSettlement(attachment: attachment.id))
        assertUnexecuted(await attachment.commit())
        assertUnexecuted(await attachment.undo())
        assertUnexecuted(await attachment.redo())
        assertUnexecuted(await reopened.commands.submit("new intent"))
        XCTAssertEqual(state.prepared?.id, commandID)
        XCTAssertEqual(try Data(contentsOf: state.journalURL), journal)
        XCTAssertEqual(first.host.state.revision, 0)
        XCTAssertEqual(first.host.state.receipts.count, 1)
        let retried = await attachment.retryDraft()
        guard case .accepted = retried else {
            XCTFail("Explicit restored retry failed")
            return
        }
        XCTAssertEqual(first.host.state.value, "Rejected")
        XCTAssertEqual(first.host.state.revision, 1)
        XCTAssertEqual(first.host.state.receipts.count, 2)
        attachment.disconnect()
        await reopened.close()
    }

    func testCurrentLiveRejectionStillAllowsNativeEditingBeforeAnotherExplicitCommit() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("rejected live draft")
        fixture.host.rejectNext = true
        let rejected = await attachment.commit()
        XCTAssertEqual(rejected, .rejected)
        XCTAssertTrue(fixture.session.nativeCoordinator.canRetryLiveRejection)
        XCTAssertTrue(
            fixture.session.nativeCoordinator.permitsEditing(
                attachment: attachment.id, control: adapter.control, composing: false))
        try adapter.change("fresh live intent")
        let committed = await attachment.commit()
        guard case .accepted = committed else {
            XCTFail("Current live rejection lost editing eligibility")
            return
        }
        XCTAssertEqual(fixture.host.state.value, "fresh live intent")
        XCTAssertEqual(fixture.host.state.revision, 1)
        XCTAssertEqual(fixture.host.state.receipts.count, 2)
        attachment.disconnect()
        await fixture.close()
    }

    func testDetachedRejectedDraftCannotAcquireLiveEditingProvenanceByRemounting() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (original, editor) = try await fixture.adapter()
        try editor.change("detached rejection")
        fixture.host.rejectNext = true
        let rejected = await original.commit()
        XCTAssertEqual(rejected, .rejected)
        original.disconnect()
        let (attachment, adapter) = try await fixture.adapter()
        XCTAssertFalse(fixture.session.nativeCoordinator.canRetryLiveRejection)
        XCTAssertFalse(
            fixture.session.nativeCoordinator.permitsEditing(
                attachment: attachment.id, control: adapter.control, composing: false))
        assertUnexecuted(await attachment.commit())
        let discarded = await attachment.discardDraft()
        XCTAssertEqual(discarded, .rejected)
        XCTAssertEqual(adapter.value, "")
        XCTAssertFalse(fixture.session.status.requiresDraftDecision)
        XCTAssertEqual(fixture.host.state.revision, 0)
        attachment.disconnect()
        await fixture.close()
    }

    func testLateRejectionCannotGrantEditingToAReplacementPresentation() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (original, editor) = try await fixture.adapter()
        try editor.change("rejected after detach")
        fixture.host.rejectNext = true
        fixture.host.delayed = true
        let commit = Task { await original.commit() }
        await fixture.host.waitUntilDelivery()
        original.disconnect()
        let (replacement, adapter) = try await fixture.adapter()
        fixture.host.resume()
        let rejected = await commit.value
        XCTAssertEqual(rejected, .rejected)
        XCTAssertFalse(fixture.session.nativeCoordinator.canRetryLiveRejection)
        XCTAssertFalse(
            fixture.session.nativeCoordinator.permitsEditing(
                attachment: replacement.id, control: adapter.control, composing: false))
        assertUnexecuted(await replacement.commit())
        let retried = await replacement.retryDraft()
        guard case .accepted = retried else {
            XCTFail("Replacement could not explicitly retry")
            return
        }
        XCTAssertEqual(fixture.host.state.revision, 1)
        XCTAssertEqual(fixture.host.state.receipts.count, 2)
        replacement.disconnect()
        await fixture.close()
    }

    private func assertUnexecuted(
        _ result: HistorySubmissionResult, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .unexecuted = result else {
            XCTFail("Restored evidence admitted ordinary work: \(result)", file: file, line: line)
            return
        }
    }
}
