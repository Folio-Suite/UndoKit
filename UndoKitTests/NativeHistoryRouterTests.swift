// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor final class NativeHistoryRouterTests: XCTestCase {
    func testOlderAvailabilityCannotReplaceCurrentProjectionOrFinishInvocation() throws {
        let router = NativeHistoryRouter()
        let scope = UUID(), generation = UUID()
        let current = HistorySnapshot(canUndo: true, canRedo: false,
            isSuspended: false, hasPending: false, scope: scope, generation: generation, version: 4)
        let stale = HistorySnapshot(canUndo: false, canRedo: false,
            isSuspended: false, hasPending: false, scope: scope, generation: generation, version: 3)
        router.update(snapshot: current, undoName: "Current")
        router.update(snapshot: stale)
        XCTAssertTrue(router.canUndo)
        XCTAssertEqual(router.undoActionName, "Current")
        router.update(snapshot: HistorySnapshot(canUndo: false, canRedo: false,
            isSuspended: false, hasPending: false, scope: scope, generation: generation, version: 4))
        XCTAssertTrue(router.canUndo, "A version cannot describe two different availability states")
        let invocation = try XCTUnwrap(router.beginExternalOperation())
        router.finishInvocation(invocation, snapshot: stale)
        XCTAssertTrue(router.isEditingBlocked)
        router.finishInvocation(invocation, snapshot: current, undoName: "Current")
        XCTAssertFalse(router.isEditingBlocked)
    }

    func testGenerationChangeRequiresExplicitAttachmentAndRejectsLateCompletion() throws {
        let router = NativeHistoryRouter()
        let scope = UUID()
        let old = HistorySnapshot(canUndo: true, canRedo: false,
            isSuspended: false, hasPending: false, scope: scope, generation: UUID(), version: 4)
        let fresh = HistorySnapshot(canUndo: false, canRedo: false,
            isSuspended: false, hasPending: false, scope: scope, generation: UUID(), version: 5)
        var states: [NativeHistoryRoutingState] = []
        router.routingStateChanged = { states.append($0) }
        try router.attach(snapshot: old)
        router.update(snapshot: fresh)
        XCTAssertTrue(router.requiresReattachment)
        XCTAssertFalse(router.canUndo)
        XCTAssertEqual(states.last, .reattachmentRequired)
        try router.attach(snapshot: fresh)
        XCTAssertFalse(router.requiresReattachment)
        XCTAssertFalse(router.canUndo)
        let invocation = try XCTUnwrap(router.beginExternalOperation())
        router.finishInvocation(invocation, snapshot: old)
        XCTAssertTrue(router.isEditingBlocked)
        XCTAssertFalse(router.requiresReattachment, "Retired callbacks cannot invalidate the new attachment")
        router.finishInvocation(invocation, snapshot: fresh)
        XCTAssertFalse(router.isEditingBlocked)
    }

    func testAttachmentRefusesProvisionalQueuedAndUnexplainedNativeWork() throws {
        let router = NativeHistoryRouter()
        let next = HistorySnapshot(canUndo: false, canRedo: false,
            isSuspended: false, hasPending: false, scope: UUID(), generation: UUID(), version: 1)
        router.noteProvisionalEdit()
        XCTAssertFalse(router.canAttach)
        XCTAssertThrowsError(try router.attach(snapshot: next))
        XCTAssertTrue(router.canUndo, "Refusal must preserve the provisional edit")
        router.didQueueProvisionalEdit()
        XCTAssertThrowsError(try router.attach(snapshot: next))
        router.didFinishQueuedEdit()
        router.reportUnknownRegistration()
        XCTAssertThrowsError(try router.attach(snapshot: next))
        router.reconcileRegistrations()
        let invocation = try XCTUnwrap(router.beginExternalOperation())
        XCTAssertThrowsError(try router.attach(snapshot: next))
        router.finishInvocation(invocation, snapshot: HistorySnapshot(canUndo: false, canRedo: false,
            isSuspended: false, hasPending: false))
        XCTAssertTrue(router.canAttach)
        try router.attach(snapshot: next)
        XCTAssertFalse(router.undoManager.canUndo)
    }

    func testDuplicateCompletionCannotFinishAnotherInvocationAtTheSameVersion() throws {
        let router = NativeHistoryRouter()
        let snapshot = HistorySnapshot(canUndo: true, canRedo: false,
            isSuspended: false, hasPending: false, scope: UUID(), generation: UUID(), version: 1)
        router.update(snapshot: snapshot)
        let first = try XCTUnwrap(router.beginExternalOperation())
        XCTAssertNil(router.beginExternalOperation(), "An active native operation cannot be replaced")
        router.finishInvocation(first, snapshot: snapshot)
        let second = try XCTUnwrap(router.beginExternalOperation())
        router.finishInvocation(first, snapshot: snapshot)
        XCTAssertTrue(router.isEditingBlocked, "A repeated old completion must not finish the new operation")
        router.finishInvocation(second, snapshot: snapshot)
        XCTAssertFalse(router.isEditingBlocked)
    }

    func testProvisionalUndoRoutesOnceAndWaitsForFinalizedAvailability() throws {
        let router = NativeHistoryRouter()
        var settled = 0
        var undoRequests = 0
        var barriers: [Bool] = []
        router.settleEditing = { settled += 1; return true }
        router.undoRequested = { undoRequests += 1 }
        router.barrierChanged = { barriers.append($0) }
        router.update(snapshot: HistorySnapshot(canUndo: false, canRedo: false,
            isSuspended: false, hasPending: false))
        XCTAssertEqual(undoRequests, 0, "Attaching availability must not replay an edit")

        router.noteProvisionalEdit()
        XCTAssertTrue(router.undoManager.canUndo)
        router.undoManager.undo()
        XCTAssertEqual(settled, 1)
        XCTAssertEqual(undoRequests, 1)
        XCTAssertTrue(router.isEditingBlocked)
        XCTAssertFalse(router.undoManager.canUndo)

        router.undoManager.undo()
        XCTAssertEqual(undoRequests, 1, "A second keypress must not queue another native reversal")
        let invocation = try XCTUnwrap(router.pendingInvocationID)
        router.finishInvocation(invocation, snapshot: HistorySnapshot(canUndo: true, canRedo: false,
            isSuspended: false, hasPending: false), undoName: "Edit")
        XCTAssertFalse(router.isEditingBlocked)
        XCTAssertTrue(router.undoManager.canUndo)
        XCTAssertEqual(router.undoManager.undoActionName, "Edit")
        XCTAssertFalse(barriers.last ?? true)
    }

    func testMarkedTextSettlementRefusesUndoWithoutCallingHost() {
        let router = NativeHistoryRouter()
        var calls = 0
        router.update(snapshot: HistorySnapshot(canUndo: true, canRedo: false,
            isSuspended: false, hasPending: false))
        router.settleEditing = { false }
        router.undoRequested = { calls += 1 }
        router.undoManager.undo()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(router.isEditingBlocked)
        XCTAssertTrue(router.undoManager.canUndo)
    }

    func testUnexplainedNativeRegistrationPausesUntilReconciled() {
        let router = NativeHistoryRouter()
        let manager = router.undoManager
        let target = NSObject()
        manager.groupsByEvent = false
        router.update(snapshot: HistorySnapshot(canUndo: true, canRedo: false,
            isSuspended: false, hasPending: false))
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: target) { _ in }
        manager.endUndoGrouping()

        XCTAssertTrue(router.hasRegistrationMismatch)
        XCTAssertTrue(router.isEditingBlocked)
        XCTAssertFalse(manager.canUndo)
        router.reconcileRegistrations()
        XCTAssertFalse(router.hasRegistrationMismatch)
        XCTAssertTrue(manager.canUndo)
    }

    func testKnownProvisionalRegistrationCanQueueBeforeFinalization() {
        let router = NativeHistoryRouter()
        let manager = router.undoManager
        let target = NSObject()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        router.noteProvisionalEdit()
        manager.registerUndo(withTarget: target) { _ in }
        manager.endUndoGrouping()
        XCTAssertFalse(router.hasRegistrationMismatch)

        router.didQueueProvisionalEdit()
        XCTAssertTrue(manager.canUndo, "A queued typing group remains eligible for immediate Undo")
        router.didFinishQueuedEdit()
        XCTAssertFalse(manager.canUndo)
    }
}
