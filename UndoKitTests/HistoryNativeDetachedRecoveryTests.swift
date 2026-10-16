// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import UndoKit

@MainActor final class HistoryNativeDetachedRecoveryTests: XCTestCase {
    func testBlockedJournalReleasesKnownPresentationAndReopensCapturedDraftExactlyOnce() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        var pair: (HistoryAttachment, NativeFieldTestAdapter)? = try await fixture.adapter()
        weak let adapter = pair?.1
        let obstruction = try XCTUnwrap(fixture.session.configuration?.journalDirectory)
        try Data("blocked journal directory".utf8).write(to: obstruction)
        try pair!.1.change("Unsettled release")
        XCTAssertEqual(fixture.session.status.phase, .blocked)
        pair?.0.disconnect()
        pair = nil
        XCTAssertNil(adapter)
        XCTAssertEqual(fixture.session.nativeCoordinator.fields[fixture.field.id]?.proposed, "Unsettled release")
        XCTAssertTrue(fixture.session.status.requiresDraftDecision)
        await fixture.session.close()
        XCTAssertFalse(fixture.host.closed)
        XCTAssertEqual(fixture.session.status.phase, .blocked)
        try FileManager.default.removeItem(at: obstruction)
        await fixture.session.close()
        XCTAssertTrue(fixture.host.closed)
        let reopened = try await fixture.reopen()
        let (attachment, restored) = try await reopened.adapter()
        XCTAssertEqual(restored.value, "Unsettled release")
        XCTAssertTrue(reopened.session.status.requiresDraftDecision)
        let result = await attachment.retryDraft()
        guard case .accepted = result else {
            XCTFail("Captured draft failed explicit retry")
            return
        }
        XCTAssertEqual(fixture.host.state.value, "Unsettled release")
        XCTAssertEqual(fixture.host.state.revision, 1)
        XCTAssertEqual(fixture.host.state.receipts.count, 1)
        attachment.disconnect()
        await reopened.close()
    }

    func testBlockedJournalCanReleaseKnownAdapterWhilePreservingUnknownCallbackGraph() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        var pair: (HistoryAttachment, NativeFieldTestAdapter)? = try await fixture.adapter()
        weak let adapter = pair?.1
        let obstruction = try XCTUnwrap(fixture.session.configuration?.journalDirectory)
        try Data("blocked".utf8).write(to: obstruction)
        try pair!.1.change("preserved values")
        var marker: NSObject? = NSObject()
        weak let graph = marker
        fixture.session.nativeCoordinator.undoManager.registerUndo(withTarget: marker!) { [kept = marker!] _ in
            _ = kept
            XCTFail("Unknown callback must never execute")
        }
        marker = nil
        pair?.0.disconnect()
        pair = nil
        XCTAssertNil(adapter)
        XCTAssertNotNil(graph)
        try FileManager.default.removeItem(at: obstruction)
        await fixture.session.close()
        XCTAssertEqual(fixture.session.status.phase, .blocked)
        XCTAssertFalse(fixture.host.closed)
        XCTAssertNotNil(graph)
        try await fixture.session.reconcileNativeRegistrations()
        XCTAssertNil(graph)
        await fixture.session.close()
        XCTAssertTrue(fixture.host.closed)
        XCTAssertEqual(fixture.host.state.revision, 0)
        await fixture.close()
    }

    func testDetachCannotReplacePreparedIntentWithAnUnexplainedControlValue() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        var pair: (HistoryAttachment, NativeFieldTestAdapter)? = try await fixture.adapter()
        weak let adapter = pair?.1
        try pair!.1.change("accepted once")
        fixture.host.delayed = true
        let committingAttachment = try XCTUnwrap(pair?.0)
        let commit = Task { await committingAttachment.commit() }
        await fixture.host.waitUntilDelivery()
        fixture.host.failReads = true
        fixture.host.resume()
        guard case .accepted = await commit.value else {
            XCTFail("Acceptance receipt lost")
            return
        }
        let state = try XCTUnwrap(fixture.session.nativeCoordinator.fields[fixture.field.id])
        let preparedID = state.prepared?.id
        pair?.1.value = "unexplained replacement"
        pair?.0.disconnect()
        pair = nil
        XCTAssertNotNil(adapter)
        XCTAssertEqual(state.proposed, "accepted once")
        XCTAssertEqual(state.prepared?.id, preparedID)
        XCTAssertEqual(fixture.session.status.issue?.cause, .identityConflict)
        adapter?.value = "accepted once"
        fixture.host.failReads = false
        let result = await fixture.session.retryDraft()
        guard case .accepted = result else {
            XCTFail("Exact prepared recovery failed")
            return
        }
        XCTAssertNil(adapter)
        XCTAssertEqual(fixture.host.state.revision, 1)
        await fixture.close()
    }
}
