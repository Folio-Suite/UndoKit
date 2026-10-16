// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import UndoKit

@MainActor final class HistoryNativeCoordinatorTests: XCTestCase {
    func testTypedCommandSettlesLiveFieldThroughSameQueueAndRefreshesMultipleAttachments() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (first, adapter) = try await fixture.adapter()
        let (second, passive) = try await fixture.adapter()
        try adapter.change("typing")
        XCTAssertEqual(passive.value, "")
        guard case .accepted = await fixture.commands.submit("semantic") else {
            XCTFail("Submission failed")
            return
        }
        XCTAssertEqual(fixture.host.state.value, "semantic")
        XCTAssertEqual(fixture.host.state.revision, 2)
        XCTAssertEqual(adapter.value, "semantic")
        XCTAssertEqual(passive.value, "semantic")
        XCTAssertEqual(adapter.retirements.count, 1)
        first.disconnect()
        second.disconnect()
        await fixture.close()
    }
    func testRejectedNativePrerequisiteStopsSemanticAndDoesNotUndoOlderGroup() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        _ = await fixture.commands.submit("older")
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("rejected draft")
        fixture.host.rejectNext = true
        let result = await fixture.session.undo()
        guard case .unexecuted(let failure) = result else {
            XCTFail("Dependent inverse was not explicitly unexecuted")
            return
        }
        XCTAssertEqual(failure.cause, .prerequisiteRejected)
        XCTAssertEqual(fixture.host.state.value, "older")
        XCTAssertEqual(fixture.host.state.revision, 1)
        XCTAssertEqual(adapter.retirements.count, 0)
        XCTAssertTrue(fixture.session.status.requiresDraftDecision)
        attachment.disconnect()
        await fixture.close()
    }
    func testCompositionFinishesBehindReservedSemanticBarrier() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("marked", composing: true)
        let semantic = Task { await fixture.commands.submit("semantic") }
        while fixture.session.status.phase != .busy { await Task.yield() }
        XCTAssertFalse(
            fixture.session.nativeCoordinator.permitsEditing(
                attachment: attachment.id, control: UUID(), composing: false))
        XCTAssertTrue(
            fixture.session.nativeCoordinator.permitsEditing(
                attachment: attachment.id, control: adapter.control, composing: true))
        try adapter.change("finished", composing: false)
        guard case .accepted = await semantic.value else {
            XCTFail("Dependent operation failed")
            return
        }
        XCTAssertEqual(fixture.host.state.revision, 2)
        XCTAssertEqual(fixture.host.state.value, "semantic")
        attachment.disconnect()
        await fixture.close()
    }
    func testClosePreservesMarkedDraftAndDoesNotStrandCompositionWaiter() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("marked", composing: true)
        let semantic = Task { await fixture.commands.submit("never executed") }
        while fixture.session.status.phase != .busy { await Task.yield() }
        await fixture.session.close()
        _ = await semantic.value
        XCTAssertEqual(fixture.session.status.phase, .closed)
        XCTAssertTrue(fixture.host.closed)
        XCTAssertEqual(fixture.host.state.revision, 0)
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path)
        XCTAssertTrue(files.contains(where: { $0.hasSuffix("7469746c65.json") }))
        attachment.disconnect()
        await fixture.close()
    }
    func testAcceptedReceiptSurvivesFailedAuthoritativeRefreshAndBlocksFollowers() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("accepted once")
        fixture.host.delayed = true
        let commit = Task { await attachment.commit() }
        await fixture.host.waitUntilDelivery()
        let follower = Task { await fixture.commands.submit("must remain unexecuted") }
        await Task.yield()
        fixture.host.failReads = true
        fixture.host.resume()
        guard case .accepted = await commit.value else {
            XCTFail("Accepted receipt was lost")
            return
        }
        guard case .unexecuted = await follower.value else {
            XCTFail("Follower was not explicitly refused")
            return
        }
        XCTAssertEqual(fixture.host.state.value, "accepted once")
        XCTAssertEqual(fixture.host.state.revision, 1)
        XCTAssertEqual(adapter.retirements.count, 0)
        XCTAssertTrue(fixture.session.status.isEditingBlocked)
        fixture.host.failReads = false
        guard case .accepted = await attachment.retryDraft() else {
            XCTFail("Exact prepared retry failed")
            return
        }
        XCTAssertEqual(fixture.host.state.revision, 1)
        XCTAssertEqual(adapter.retirements.count, 1)
        attachment.disconnect()
        await fixture.close()
    }
    func testUnknownRegistrationSurvivesDetachAndBlockedCloseUntilCertification() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, _) = try await fixture.adapter()
        var target: NSObject? = NSObject()
        weak let retained = target
        fixture.session.nativeCoordinator.undoManager.registerUndo(withTarget: target!) { [kept = target!] _ in _ = kept
        }
        target = nil
        attachment.disconnect()
        await fixture.session.close()
        XCTAssertEqual(fixture.session.status.phase, .blocked)
        XCTAssertFalse(fixture.host.closed)
        XCTAssertNotNil(retained)
        try await fixture.session.nativeCoordinator.reconcileNativeRegistrations()
        XCTAssertNil(retained)
        await fixture.session.close()
        XCTAssertTrue(fixture.host.closed)
        await fixture.close()
    }
    func testFieldIdentityRefusesDifferentActualOperationEvenWithMatchingMetadata() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, _) = try await fixture.adapter()
        let other = try fixture.host.operation()
        do {
            _ = try fixture.session.commands(for: other)
            XCTFail("Conflicting handler declaration was accepted")
        } catch let failure as HistoryFailure { XCTAssertEqual(failure.cause, .identityConflict) }
        attachment.disconnect()
        await fixture.close()
    }
    func testEqualFieldValueDoesNotEstablishEqualAuthoritativeRevision() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("draft")
        fixture.host.state.revision += 1
        guard case .unexecuted = await attachment.commit() else {
            XCTFail("Stale revision was accepted")
            return
        }
        XCTAssertEqual(fixture.host.state.value, "")
        XCTAssertEqual(adapter.retirements.count, 0)
        attachment.disconnect()
        await fixture.close()
    }
    func testSemanticNoopRetiresKnownLiveWorkWithoutInferringAcceptance() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("")
        let result = await attachment.commit()
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(fixture.host.state.revision, 0)
        XCTAssertEqual(adapter.retirements.count, 1)
        attachment.disconnect()
        await fixture.close()
    }
    func testQueuedFollowersCannotAutomaticallyRetryRejectedNativePrerequisite() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("rejected prerequisite")
        fixture.host.rejectNext = true
        fixture.host.delayed = true
        let first = Task { await fixture.commands.submit("first dependent") }
        await fixture.host.waitUntilDelivery()
        let second = Task { await fixture.commands.submit("second dependent") }
        await Task.yield()
        fixture.host.resume()
        if case .accepted = await first.value { XCTFail("First dependent was delivered") }
        if case .accepted = await second.value { XCTFail("Second dependent retried rejected intent") }
        XCTAssertEqual(fixture.host.state.receipts.count, 1)
        XCTAssertEqual(fixture.host.state.revision, 0)
        XCTAssertEqual(fixture.host.state.value, "")
        attachment.disconnect()
        await fixture.close()
    }
    func testDeferredNativeBoundaryReturnsFalseUntilCompositionActuallyEnds() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("composing", composing: true)
        XCTAssertFalse(fixture.session.nativeCoordinator.requestSettlement(attachment: attachment.id))
        XCTAssertEqual(fixture.host.state.revision, 0)
        try adapter.change("finished", composing: false)
        await fixture.session.waitForNativeOperations()
        XCTAssertEqual(fixture.host.state.revision, 1)
        XCTAssertEqual(fixture.host.state.value, "finished")
        attachment.disconnect()
        await fixture.close()
    }
    func testSettlementRecapturesMarkedRangeWhenNativeNotificationPrecedesCompositionUpdate() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("initial text")
        // Native AppKit can publish its text change before updating the marked range.
        adapter.value = "marked text"
        adapter.composing = true
        XCTAssertFalse(fixture.session.nativeCoordinator.requestSettlement(attachment: attachment.id))
        XCTAssertEqual(fixture.host.state.revision, 0)
        XCTAssertTrue(adapter.composing)
        adapter.composing = false
        fixture.session.nativeCoordinator.compositionChanged(attachment: attachment.id)
        await fixture.session.waitForNativeOperations()
        XCTAssertEqual(fixture.host.state.value, "marked text")
        XCTAssertEqual(fixture.host.state.revision, 1)
        attachment.disconnect()
        await fixture.close()
    }
}
