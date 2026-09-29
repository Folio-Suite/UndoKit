// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import Foundation
import Testing
import ScaleProbe

@MainActor @Suite(.serialized) struct StoreTests {
@Test func restorationRetainsDisplacedContinuationAndRoundTrips() throws {
    let store = try HistoryStore.temporary()
    defer { try? store.close(); if ProcessInfo.processInfo.environment["KEEP_FIXTURES"] != "1" { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) } }
    let a = try store.append(scope: "folio", actions: [.set("text", "A")])
    let b = try store.append(scope: "folio", actions: [.set("text", "B")])
    let c = try store.append(scope: "folio", actions: [.set("text", "C")])
    let restored = try store.restore(scope: "folio", target: a)
    #expect(try store.reconstruct(scope: "folio", node: restored).state == ["text": "A"])
    #expect(try store.reconstruct(scope: "folio", node: c).state == ["text": "C"])
    #expect(try store.node(b) != nil)
    #expect(try store.node(restored)?.origin == a)
    try store.undo(scope: "folio")
    #expect(try store.currentState(scope: "folio") == ["text": "C"])
    try store.redo(scope: "folio")
    #expect(try store.currentState(scope: "folio") == ["text": "A"])
}

@Test func checkpointGapAndIndependentProtection() throws {
    let store = try HistoryStore.temporary()
    defer { try? store.close(); if ProcessInfo.processInfo.environment["KEEP_FIXTURES"] != "1" { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) } }
    let shared = Resource(store: "images", key: "shared", version: "v1")
    let a = try store.append(scope: "folio", actions: [.set("text", "A")], resources: [shared])
    let b = try store.append(scope: "folio", actions: [.set("text", "B")])
    let c = try store.append(scope: "folio", actions: [.set("text", "C")])
    let hold = try store.hold(node: a, kind: "history")
    _ = try store.checkpoint(scope: "folio", node: b, resources: [shared])
    let plan = try store.beginPlan(scope: "folio", target: c)
    let first = try store.planPage(plan, offset: 0, maxEntries: 1)
    #expect(first.nodeIDs == [c])
    #expect(try store.prune(targetGroups: 1).unmetTarget)
    #expect(try store.node(a) != nil)
    try store.releaseHold(hold)
    try store.releasePlan(plan)
    let result = try store.prune(targetGroups: 1)
    #expect(result.removedGroups > 0)
    #expect(try store.reconstruct(scope: "folio", node: c).state == ["text": "C"])
    #expect(try store.reconstruct(scope: "folio", node: c).baseline == b)
    #expect(try store.references(store: "images").contains(shared))
}

@Test func boundedRefusalPrecedesNewHistory() throws {
    var limits = Limits(); limits.maxPayload = 4; limits.maxGroupBytes = 6
    let store = try HistoryStore.temporary(limits: limits)
    defer { try? store.close(); if ProcessInfo.processInfo.environment["KEEP_FIXTURES"] != "1" { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) } }
    #expect(throws: ProofError.refused("payload bytes")) {
        _ = try store.append(scope: "folio", actions: [.set("x", "12345")])
    }
    #expect(try store.head(scope: "folio") == nil)
    let id = try store.append(scope: "folio", actions: [Effect(key: "x", value: Data("1".utf8), command: Data("cmd".utf8))])
    #expect(try store.node(id) != nil)
}

@Test func selectedRecoveryRestoresAbsentMaterialAndScopeIsolated() throws {
    let store = try HistoryStore.temporary()
    defer { try? store.close(); if ProcessInfo.processInfo.environment["KEEP_FIXTURES"] != "1" { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) } }
    let empty = try store.append(scope: "one", actions: [.set("other", "v")])
    _ = try store.append(scope: "one", actions: [.set("selected", "new")])
    let selected = try store.recoverSelected(scope: "one", target: empty, keys: ["selected"])
    #expect(try store.reconstruct(scope: "one", node: selected).state == ["other": "v"])
    #expect(throws: ProofError.missing(empty)) {
        _ = try store.reconstruct(scope: "two", node: empty)
    }
}

@Test func releasingStateHoldAllowsConsolidatedStateToPrune() throws {
    let store = try HistoryStore.temporary()
    defer { try? store.close(); if ProcessInfo.processInfo.environment["KEEP_FIXTURES"] != "1" { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) } }
    let a = try store.append(scope: "one", actions: [.set("x", "a")])
    let b = try store.append(scope: "one", actions: [.set("x", "b")])
    _ = try store.checkpoint(scope: "one", node: b)
    let held = try store.hold(node: a, kind: "state")
    #expect(try store.prune(targetGroups: 1).unmetTarget)
    try store.releaseHold(held)
    #expect(try store.prune(targetGroups: 1).removedGroups == 1)
    #expect(try store.node(a) == nil)
}


@Test func historyHoldCrossesCheckpointAndOverlappingCurrentPath() throws {
    let store = try HistoryStore.temporary()
    defer { try? store.close(); if ProcessInfo.processInfo.environment["KEEP_FIXTURES"] != "1" { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) } }
    let a = try store.append(scope: "folio", actions: [.set("x", "a")])
    let b = try store.append(scope: "folio", actions: [.set("x", "b")])
    _ = try store.checkpoint(scope: "folio", node: b)
    _ = try store.append(scope: "folio", actions: [.set("x", "c")])
    let d = try store.append(scope: "folio", actions: [.set("x", "d")])
    let hold = try store.hold(node: d, kind: "history", until: a)
    let protected = try store.prune(targetGroups: 1)
    #expect(protected.retainedGroups == 4)
    #expect(try store.node(a) != nil)
    try store.releaseHold(hold)
    let afterRelease = try store.prune(targetGroups: 1)
    #expect(afterRelease.removedGroups == 1)
    #expect(try store.node(a) == nil)
}


@Test func interruptedSessionPlanExpiresButCheckpointSurvives() throws {
    let store = try HistoryStore.temporary()
    let url = store.url
    defer { try? store.close(); if ProcessInfo.processInfo.environment["KEEP_FIXTURES"] != "1" { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
    let a = try store.append(scope: "folio", actions: [.set("x", "a")])
    let b = try store.append(scope: "folio", actions: [.set("x", "b")])
    _ = try store.checkpoint(scope: "folio", node: b)
    let plan = try store.beginPlan(scope: "folio", target: a)
    try store.close()
    let reopened = try HistoryStore(url: url)
    defer { try? reopened.close() }
    #expect(throws: ProofError.missing(plan)) { try reopened.releasePlan(plan) }
    #expect(try reopened.prune(targetGroups: 1).removedGroups == 1)
    #expect(try reopened.reconstruct(scope: "folio", node: b).state == ["x": "b"])
}

}
