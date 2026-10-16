// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import UndoKit

@MainActor final class HistoryPrerequisiteCancellationTests: XCTestCase {
    func testCancelledDependentCompletesWhileCompositionWaitsAndNeverDeliversItsIntent() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("marked", composing: true)
        let completed = expectation(description: "Dependent cancellation completed")
        let semantic = Task {
            let result = await fixture.commands.submit("cancelled semantic")
            completed.fulfill()
            return result
        }
        await waitForCompositionPrerequisite(fixture.session)
        semantic.cancel()
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(fixture.host.state.revision, 0)
        XCTAssertEqual(fixture.session.status.phase, .busy)
        XCTAssertTrue(adapter.composing)
        let fresh = Task { await fixture.commands.submit("fresh semantic") }
        try adapter.change("finished typing", composing: false)
        assertCancelledUnexecuted(await semantic.value)
        guard case .accepted = await fresh.value else {
            XCTFail("Independent fresh intent did not finish")
            return
        }
        XCTAssertEqual(fixture.host.state.revision, 2)
        XCTAssertEqual(fixture.host.state.value, "fresh semantic")
        let delivered = fixture.host.state.receipts.values.flatMap { $0.evidence.map(\.redo) }
        XCTAssertFalse(delivered.contains("cancelled semantic"))
        XCTAssertTrue(delivered.contains("finished typing"))
        attachment.disconnect()
        await fixture.close()
    }

    func testCancelledDependentDoesNotCancelAlreadyDeliveredNativePrerequisite() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("native effect")
        fixture.host.delayed = true
        let completed = expectation(description: "Dependent completed before native delivery returns")
        let semantic = Task {
            let result = await fixture.commands.submit("cancelled semantic")
            completed.fulfill()
            return result
        }
        await fixture.host.waitUntilDelivery()
        semantic.cancel()
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(fixture.host.state.revision, 0)
        fixture.host.resume()
        assertCancelledUnexecuted(await semantic.value)
        guard case .accepted = await fixture.commands.submit("fresh semantic") else {
            XCTFail("Native prerequisite did not release admission")
            return
        }
        XCTAssertEqual(fixture.host.state.revision, 2)
        XCTAssertEqual(adapter.retirements.count, 1)
        let delivered = fixture.host.state.receipts.values.flatMap { $0.evidence.map(\.redo) }
        XCTAssertFalse(delivered.contains("cancelled semantic"))
        XCTAssertTrue(delivered.contains("native effect"))
        attachment.disconnect()
        await fixture.close()
    }

    func testCancellationAfterOwnDeliveryKeepsAuthoritativeAcceptedReceipt() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        fixture.host.delayed = true
        let completed = expectation(description: "Prepared request must await its authoritative outcome")
        completed.isInverted = true
        var deliveryReleased = false
        let semantic = Task {
            let result = await fixture.commands.submit("delivered semantic")
            if !deliveryReleased { completed.fulfill() }
            return result
        }
        await fixture.host.waitUntilDelivery()
        semantic.cancel()
        await fulfillment(of: [completed], timeout: 0.05)
        deliveryReleased = true
        fixture.host.resume()
        guard case .accepted = await semantic.value else {
            XCTFail("Cancellation erased the delivered request's receipt")
            return
        }
        XCTAssertEqual(fixture.host.state.value, "delivered semantic")
        XCTAssertEqual(fixture.host.state.revision, 1)
        await fixture.close()
    }

    func testCloseAfterCancelledCompositionPreservesDraftAndReleasesTheWriter() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("marked draft", composing: true)
        let completed = expectation(description: "Cancelled dependent completed before closure")
        let semantic = Task {
            let result = await fixture.commands.submit("never delivered")
            completed.fulfill()
            return result
        }
        await waitForCompositionPrerequisite(fixture.session)
        semantic.cancel()
        await fulfillment(of: [completed], timeout: 1)
        await fixture.session.close()
        assertCancelledUnexecuted(await semantic.value)
        XCTAssertEqual(fixture.session.status.phase, .closed)
        XCTAssertTrue(fixture.host.closed)
        XCTAssertEqual(fixture.host.state.revision, 0)
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path)
        XCTAssertTrue(files.contains { $0.hasSuffix("7469746c65.json") })
        let reader = try await HistoryStore.open(
            at: fixture.root.appendingPathComponent("History.sqlite"), workingIdentity: fixture.host.working,
            mode: .existing, access: .readOnly)
        XCTAssertEqual(try reader.inspectScope(fixture.host.scope).pendingRecoveryCount, 0)
        try await reader.close()
        attachment.disconnect()
        await fixture.close()
    }

    private func waitForCompositionPrerequisite(_ session: HistorySession) async {
        while session.nativeCoordinator.compositionWaiters.isEmpty { await Task.yield() }
    }

    private func assertCancelledUnexecuted(
        _ result: HistorySubmissionResult, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .unexecuted(let failure) = result else {
            XCTFail("Cancelled unprepared intent did not complete as unexecuted", file: file, line: line)
            return
        }
        XCTAssertEqual(failure.cause, .cancelled, file: file, line: line)
        XCTAssertEqual(failure.stage, .admission, file: file, line: line)
    }
}
