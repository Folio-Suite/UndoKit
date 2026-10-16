// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import UndoKit

#if canImport(AppKit)
import AppKit
#endif

@MainActor final class HistoryNativeLifetimeTests: XCTestCase {
    func testNativeInvocationReservesAdmissionBeforeCallbackReturns() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("native undo target")
        fixture.session.requestNativeOperation(.undo)
        XCTAssertEqual(fixture.session.status.phase, .busy)
        XCTAssertFalse(
            fixture.session.nativeCoordinator.permitsEditing(
                attachment: attachment.id, control: adapter.control, composing: false))
        await fixture.session.waitForNativeOperations()
        XCTAssertEqual(fixture.host.state.value, "")
        XCTAssertEqual(fixture.host.state.revision, 2)
        attachment.disconnect()
        await fixture.close()
    }
    func testUnknownRegistrationArrivingWhileDeliveryDrainsBlocksClosureAndPreservesGraph() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("once")
        fixture.host.delayed = true
        let submission = Task { await attachment.commit() }
        await fixture.host.waitUntilDelivery()
        let closing = Task { await fixture.session.close() }
        await Task.yield()
        var target: NSObject? = NSObject()
        weak let graph = target
        fixture.session.nativeCoordinator.undoManager.registerUndo(withTarget: target!) { [kept = target!] _ in _ = kept
        }
        target = nil
        fixture.host.resume()
        _ = await submission.value
        await closing.value
        XCTAssertEqual(fixture.session.status.phase, .blocked)
        XCTAssertFalse(fixture.host.closed)
        XCTAssertNotNil(graph)
        try await fixture.session.reconcileNativeRegistrations()
        await fixture.session.close()
        XCTAssertTrue(fixture.host.closed)
        XCTAssertNil(graph)
        attachment.disconnect()
        await fixture.close()
    }
    func testUnknownRegistrationArrivingDuringHostCloseCannotCertifyCompleteClosure() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let attachment = try fixture.session.attach(owner: NSObject())
        let manager = attachment.undoManager
        fixture.host.delayClose = true
        let closing = Task { await fixture.session.close() }
        await fixture.host.waitUntilClose()
        var target: NSObject? = NSObject()
        weak let graph = target
        manager.registerUndo(withTarget: target!) { [kept = target!] _ in _ = kept }
        target = nil
        fixture.host.resumeClose()
        await closing.value
        XCTAssertEqual(fixture.session.status.phase, .blocked)
        XCTAssertNotNil(graph)
        XCTAssertFalse(fixture.sessions.entries.isEmpty)
        try await fixture.session.reconcileNativeRegistrations()
        await fixture.session.close()
        XCTAssertEqual(fixture.session.status.phase, .closed)
        XCTAssertNil(graph)
        attachment.disconnect()
        await fixture.close()
    }
    func testStaleSettlementIdentityCannotRetireNewerNativeStack() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        try adapter.change("first")
        let first = try XCTUnwrap(fixture.session.nativeCoordinator.capturePrerequisite())
        guard case .accepted = await attachment.commit() else { XCTFail("First settlement failed")
return }
        try adapter.change("second")
        let second = try XCTUnwrap(fixture.session.nativeCoordinator.capturePrerequisite())
        XCTAssertNotEqual(first, second)
        _ = await fixture.session.nativeCoordinator.settlePrerequisite(first) { _ in
            XCTFail("Retired work executed")
            return .rejected
        }
        XCTAssertEqual(adapter.retirements.count, 1)
        XCTAssertTrue(attachment.hasLiveTransaction)
        guard case .accepted = await attachment.commit() else { XCTFail("Second settlement failed")
return }
        XCTAssertEqual(adapter.retirements.count, 2)
        XCTAssertEqual(fixture.host.state.value, "second")
        attachment.disconnect()
        await fixture.close()
    }
    func testRetiredAttachmentCannotMutateReplacementSessionOrRetainNativeCallbacks() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        await fixture.session.close()
        XCTAssertTrue(adapter.detached)
        let reopened = try await fixture.reopen()
        guard case .unexecuted = await attachment.undo() else { XCTFail("Retired attachment executed")
return }
        XCTAssertEqual(reopened.host.state.revision, 0)
        attachment.disconnect()
        await reopened.close()
    }
    func testPhysicalStoreMaintenanceBlocksActualNativeEditAdmission() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (attachment, adapter) = try await fixture.adapter()
        let store = try XCTUnwrap(fixture.session.engine?.store)
        try await store.activity.withMaintenance(in: store) {
            XCTAssertFalse(
                fixture.session.nativeCoordinator.permitsEditing(
                    attachment: attachment.id, control: adapter.control, composing: false))
        }
        XCTAssertTrue(
            fixture.session.nativeCoordinator.permitsEditing(
                attachment: attachment.id, control: adapter.control, composing: false))
        attachment.disconnect()
        await fixture.close()
    }
    func testDelayedFieldReadCannotInstallStateAfterCompleteClosure() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let gate = NativeFieldReadGate()
        let field = HistoryField<String>(
            id: "delayed", mappingID: "delayed", codec: .json(), commands: fixture.commands,
            read: {
                await gate.pause()
                return try fixture.host.snapshot
            }, makeCommands: { _, value in [value] })
        let registering = Task { try await fixture.session.nativeCoordinator.register(field) }
        await gate.waitUntilStarted()
        await fixture.session.close()
        gate.resume()
        do {
            _ = try await registering.value
            XCTFail("Retired field installed")
        } catch let failure as HistoryFailure { XCTAssertEqual(failure.cause, .identityConflict) }
        await fixture.close()
    }
    #if canImport(AppKit)
    func testPublicBindingDisconnectedDuringFieldReadCannotReplaceNativeRouting() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let gate = NativeFieldReadGate()
        let field = HistoryField<String>(
            id: "delayed", mappingID: "delayed", codec: .json(), commands: fixture.commands,
            read: {
                await gate.pause()
                return try fixture.host.snapshot
            }, makeCommands: { _, value in [value] })
        let attachment = try fixture.session.attach(owner: NSObject())
        let editor = NativeHistoryAppKitTextView()
        let binding = Task { try await attachment.bindAppKit(editors: [(editor, field)]) }
        await gate.waitUntilStarted()
        attachment.disconnect()
        gate.resume()
        do {
            _ = try await binding.value
            XCTFail("Disconnected binding installed native routing")
        } catch let failure as HistoryFailure { XCTAssertEqual(failure.cause, .identityConflict) }
        XCTAssertNil(editor.historyFacade)
        await fixture.close()
    }
    #endif
    func testIdleGenerationRetiresOldAttachmentsAndAllowsFreshFieldDeclaration() async throws {
        let fixture = try await NativeFieldTestFixture.open()
        let (old, adapter) = try await fixture.adapter()
        _ = try fixture.session.advanced.clearHistory(adopting: HistoryPayload(family: "baseline", data: Data()))
        XCTAssertTrue(adapter.detached)
        guard case .unexecuted = await old.commit() else {
            XCTFail("Old attachment entered replacement generation")
            return
        }
        let commands = try fixture.session.commands(for: fixture.commands.operation)
        let field = HistoryField<String>(
            id: fixture.field.id, mappingID: fixture.field.mappingID, codec: .json(), commands: commands,
            read: { try fixture.host.snapshot }, makeCommands: { _, value in [value] })
        let fresh = try fixture.session.attach(owner: NSObject())
        let replacement = NativeFieldTestAdapter(attachment: fresh, field: field.id)
        replacement.value = try await fixture.session.nativeCoordinator.register(field)
        fresh.platform = replacement
        fixture.session.nativeCoordinator.register(replacement)
        try replacement.change("new generation")
        guard case .accepted = await fresh.commit() else {
            XCTFail("Fresh field could not enter new generation")
            return
        }
        XCTAssertEqual(fixture.host.state.value, "new generation")
        old.disconnect()
        fresh.disconnect()
        await fixture.close()
    }
}
