// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor final class NativeHistoryRouterTests: XCTestCase {
    func testProvisionalUndoRoutesOnceAndWaitsForFinalizedAvailability() {
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
        router.finishInvocation(snapshot: HistorySnapshot(canUndo: true, canRedo: false,
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
