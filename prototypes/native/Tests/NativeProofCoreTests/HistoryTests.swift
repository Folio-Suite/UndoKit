// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import NativeProofCore

@Test @MainActor func bothDirectionsSurviveRebuildWithoutReplay() throws {
    let bridge = NativeBridge(history: ProofHistory(scope: "A"))
    #expect(bridge.acceptEdit("one", name: "Typing"))
    #expect(bridge.acceptEdit("two", name: "Typing"))
    #expect(bridge.begin(undo: true, origin: "A-main"))
    #expect(bridge.finish(mode: .immediate) == .acceptedUndo)
    let data = try JSONEncoder().encode(bridge.history)
    let restored = NativeBridge(history: try JSONDecoder().decode(ProofHistory.self, from: data))
    #expect(restored.history.content == "one")
    #expect(restored.availability.undoID != nil)
    #expect(restored.availability.redoID != nil)
    #expect(restored.history.version == bridge.history.version)
}

@Test @MainActor func pendingRejectionAndInterference() {
    let bridge = NativeBridge(history: ProofHistory(scope: "A"))
    #expect(bridge.acceptEdit("one", name: "Typing"))
    #expect(bridge.begin(undo: true, origin: "A-main"))
    #expect(!bridge.begin(undo: true, origin: "A-clone"))
    #expect(!bridge.acceptEdit("blocked", name: "Typing"))
    #expect(bridge.availability.pending)
    #expect(bridge.finish(mode: .reject) == .rejected)
    #expect(bridge.history.content == "one")
    #expect(bridge.availability.undoID == nil)
    bridge.detectUnknownRegistration()
    #expect(bridge.availability.interference)
    bridge.reconcileRegistration()
    #expect(!bridge.availability.interference)
}

@Test @MainActor func unresolvedAndRedoAbandonment() {
    let bridge = NativeBridge(history: ProofHistory(scope: "A"))
    #expect(bridge.acceptEdit("one", name: "Typing"))
    #expect(bridge.acceptEdit("two", name: "Typing"))
    #expect(bridge.begin(undo: true, origin: "A"))
    #expect(bridge.finish(mode: .unresolved) == .unresolved)
    #expect(bridge.availability.suspended)
    #expect(!bridge.begin(undo: true, origin: "A"))
    bridge.reconcileUnresolved()
    #expect(bridge.begin(undo: true, origin: "A"))
    #expect(bridge.finish(mode: .immediate) == .acceptedUndo)
    #expect(bridge.acceptEdit("new", name: "Typing"))
    #expect(bridge.availability.redoID == nil)
}

@Test @MainActor func availabilityVersionsAdvanceAcrossPendingAndInterference() {
    let bridge = NativeBridge(history: ProofHistory(scope: "A"))
    let initial = bridge.availability.version
    #expect(bridge.acceptEdit("one", name: "Typing"))
    let edited = bridge.availability.version
    #expect(edited > initial)
    #expect(bridge.begin(undo: true, origin: "A"))
    let pending = bridge.availability.version
    #expect(pending > edited)
    #expect(bridge.finish(mode: .immediate) == .acceptedUndo)
    let finished = bridge.availability.version
    #expect(finished > pending)
    bridge.detectUnknownRegistration()
    #expect(bridge.availability.version > finished)
}
