// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import Foundation
import ScaleProbe

struct Generator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = 2_862_933_555_777_941_757 &* state &+ 3_037_000_493
        return state
    }
    mutating func bytes(_ count: Int) -> Data {
        var chunk = Data(count: min(count, 65_536))
        let chunkCount = chunk.count
        chunk.withUnsafeMutableBytes { raw in
            guard let raw = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<chunkCount { raw[i] = UInt8(truncatingIfNeeded: next() >> 24) }
        }
        var data = Data(capacity: count)
        while data.count < count { data.append(chunk.prefix(count - data.count)) }
        return data
    }
}

func emit(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
        fflush(stdout)
    }
}
func seconds(_ start: TimeInterval) -> Double { ProcessInfo.processInfo.systemUptime - start }
func percentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
}
func summary(_ values: [Double]) -> [String: Double] {
    ["p50": percentile(values, 0.5), "p95": percentile(values, 0.95),
     "p99": percentile(values, 0.99), "max": values.max() ?? 0]
}
func id(_ n: Int) -> String { String(format: "g-%07d", n) }
func effect(_ key: String, _ value: String, command: Data) -> Effect {
    Effect(key: key, value: Data(value.utf8), command: command)
}

@MainActor func makeFixture(kind: String, url: URL, seed: UInt64) throws {
    var random = Generator(state: seed)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let store = try HistoryStore(url: url)
    defer { try? store.close() }
    var ordinal = 0
    var encoded = 0
    var actions = 0
    var checkpoints = 0
    var branches = 1
    var oracle: [String: [String: String]] = [:]
    var expectedTargets: [String: [String: String]] = [:]
    var targets: [String: String] = [:]
    let started = ProcessInfo.processInfo.systemUptime
    func add(_ scope: String, _ payload: Int, key: String, value: String,
             multi: Bool = false, resource: Resource? = nil) throws -> String {
        ordinal += 1
        let command = random.bytes(max(0, payload - value.utf8.count))
        var members = [effect(key, value, command: command)]
        if multi {
            members.append(effect("secondary", String(ordinal), command: random.bytes(64)))
        }
        let node = try store.append(scope: scope, actions: members,
                                    resources: resource.map { [$0] } ?? [],
                                    nodeID: id(ordinal), durable: false)
        oracle[scope, default: [:]][key] = value
        if multi { oracle[scope, default: [:]]["secondary"] = String(ordinal) }
        encoded += payload + (multi ? 64 + String(ordinal).utf8.count : 0)
        actions += members.count
        if ordinal % 100 == 0 { try store.flush() }
        if ordinal % 1_000 == 0 { emit(["phase": "build", "groups": ordinal, "seconds": seconds(started)]) }
        return node
    }
    switch kind {
    case "smoke":
        for i in 0..<20 {
            let node = try add("folio", 1_024, key: "paragraph-" + String(i % 4), value: String(i))
            if i == 19 { targets["end"] = node }
        }
        try store.flush()
        guard try store.currentState(scope: "folio") == oracle["folio"] else {
            throw ProofError.gap("smoke oracle mismatch")
        }
    case "ordinary":
        for i in 0..<10_000 {
            let payload = i % 1_000 == 999 ? 1_048_576 : 1_024
            let node = try add("folio", payload, key: "paragraph-" + String(i % 32),
                               value: String(i), multi: i % 20 == 0,
                               resource: i % 200 == 0 ? Resource(store: "assets", key: "shared", version: "1") : nil)
            if i == 100 {
                targets["nearBeginning"] = node
                expectedTargets["nearBeginning"] = oracle["folio"]!
            }
            if i == 9_999 { targets["end"] = node }
        }
        try store.flush()
        let expected = oracle["folio"]!
        let actual = try store.currentState(scope: "folio")
        guard actual == expected else { throw ProofError.gap("ordinary oracle mismatch") }
    case "large":
        for i in 0..<1_000 {
            let node = try add("folio", i % 100 == 0 ? 4_096 : 256,
                               key: "trunk-" + String(i % 32), value: String(i), multi: i % 20 == 0)
            if i == 100 {
                targets["nearBeginning"] = node
                expectedTargets["nearBeginning"] = oracle["folio"]!
            }
            if i == 999 { targets["fork"] = node }
        }
        try store.flush()
        let fork = targets["fork"]!
        let forkState = oracle["folio"]!
        for branch in 0..<100 {
            if branch > 0 {
                try store.forkFixture(scope: "folio", from: fork)
                oracle["folio"] = forkState
            }
            branches = branch + 1
            for i in 0..<990 {
                let node = try add("folio", i % 100 == 0 ? 4_096 : 256,
                                   key: "branch-" + String(i % 32), value: "\(branch):\(i)",
                                   multi: i % 20 == 0,
                                   resource: i % 100 == 0 ? Resource(store: "assets", key: "shared", version: "1") : nil)
                if i == 500 && branch == 0 {
                    targets["divergent"] = node
                    expectedTargets["divergent"] = oracle["folio"]!
                }
                if i == 500 && branch == 99 { targets["midpoint"] = node }
                if i == 989 && branch == 99 { targets["end"] = node }
            }
            try store.flush()
            _ = try store.checkpoint(scope: "folio", node: id(ordinal),
                                     resources: [Resource(store: "assets", key: "shared", version: "1")])
            checkpoints += 1
        }
        let endExpected = oracle["folio"]!
        guard try store.currentState(scope: "folio") == endExpected else {
            throw ProofError.gap("large end oracle mismatch")
        }
        let early = try store.reconstruct(scope: "folio", node: targets["nearBeginning"]!)
        guard early.state == expectedTargets["nearBeginning"] else {
            throw ProofError.gap("near beginning oracle mismatch")
        }
        let divergent = try store.reconstruct(scope: "folio", node: targets["divergent"]!)
        guard divergent.state == expectedTargets["divergent"] else {
            throw ProofError.gap("divergent oracle mismatch")
        }
        emit(["phase": "distantRecovery", "nearRecords": early.recordsVisited,
              "nearBytes": early.bytesRead, "divergentRecords": divergent.recordsVisited,
              "divergentBytes": divergent.bytesRead])
        let restoreID = try store.restore(scope: "folio", target: targets["nearBeginning"]!)
        guard try store.currentState(scope: "folio") == early.state else {
            throw ProofError.gap("restored early mismatch")
        }
        try store.undo(scope: "folio")
        guard try store.currentState(scope: "folio") == endExpected else {
            throw ProofError.gap("displaced end mismatch")
        }
        try store.redo(scope: "folio")
        guard try store.currentState(scope: "folio") == early.state else {
            throw ProofError.gap("redo restoration mismatch")
        }
        targets["restoration"] = restoreID
        _ = try store.checkpoint(scope: "folio", node: targets["nearBeginning"]!)
        checkpoints += 1
    case "kitchen":
        var oldCheckpoints: [String: String] = [:]
        var recent: [String: [String]] = [:]
        for i in 0..<10_000 {
            let scope = "kitchen-" + String(i % 4)
            let localStep = i / 4
            let node = try add(scope, 256, key: "recipe-" + String(i % 16), value: String(i),
                               multi: i % 25 == 0)
            recent[scope, default: []].append(node)
            if recent[scope]!.count > 101 { recent[scope]!.removeFirst() }
            if i == 9_999 { targets["end"] = node }
            if localStep >= 199 && localStep % 100 == 99 {
                try store.flush()
                let baseline = recent[scope]!.first!
                let cp = try store.checkpoint(scope: scope, node: baseline)
                checkpoints += 1
                if let old = oldCheckpoints[scope] { try store.dropCheckpoint(old) }
                oldCheckpoints[scope] = cp
            }
            if i >= 799 && i % 400 == 399 {
                let result = try store.prune(targetGroups: 404)
                emit(["phase": "turnover", "groups": i + 1, "removed": result.removedGroups,
                      "retained": result.retainedGroups, "unmet": result.unmetTarget])
            }
        }
        try store.flush()
        for scope in oracle.keys {
            try store.configureUndoDepth(scope: scope, groups: 100)
            guard try store.currentState(scope: scope) == oracle[scope] else {
                throw ProofError.gap("kitchen oracle mismatch")
            }
            for _ in 0..<100 { try store.undo(scope: scope) }
            guard (try? store.undo(scope: scope)) == nil else { throw ProofError.gap("undo allowance exceeded") }
            for _ in 0..<100 { try store.redo(scope: scope) }
            guard try store.currentState(scope: scope) == oracle[scope] else {
                throw ProofError.gap("kitchen redo oracle mismatch")
            }
        }
        emit(["phase": "allowance", "scopes": 4, "undoGroupsPerScope": 100, "redoGroupsPerScope": 100])
    case "payload":
        for i in 0..<100 {
            let node = try add("payload", 8 * 1_024 * 1_024, key: "blobMarker", value: String(i))
            if i == 99 { targets["end"] = node }
            try store.flush()
        }
        guard try store.currentState(scope: "payload") == oracle["payload"] else {
            throw ProofError.gap("payload oracle mismatch")
        }
    default: throw ProofError.refused("unknown fixture")
    }
    targets["scope"] = kind == "payload" ? "payload" : (kind == "kitchen" ? "kitchen-3" : "folio")
    let expectedFile = url.deletingLastPathComponent().appendingPathComponent("expected.json")
    let expectedData = try JSONSerialization.data(withJSONObject: expectedTargets, options: [.sortedKeys])
    try expectedData.write(to: expectedFile)
    let targetFile = url.deletingLastPathComponent().appendingPathComponent("targets.json")
    let targetData = try JSONSerialization.data(withJSONObject: targets, options: [.sortedKeys, .prettyPrinted])
    try targetData.write(to: targetFile)
    emit(["phase": "fixtureComplete", "kind": kind, "seed": seed, "groups": ordinal,
          "actions": actions, "branches": branches, "checkpoints": checkpoints,
          "encodedBytes": encoded, "seconds": seconds(started), "footprintBytes": try store.fileFootprint()])
    var durations: [Double] = []
    for i in 0..<1_000 {
        let start = ProcessInfo.processInfo.systemUptime
        _ = try store.append(scope: "small-phase", actions: [.set("k", String(i))],
                             nodeID: "small-" + String(i))
        durations.append(seconds(start) * 1_000)
    }
    emit(["phase": "smallOperations", "count": durations.count, "milliseconds": summary(durations),
          "footprintBytes": try store.fileFootprint()])
}

@MainActor func consolidate(url: URL) throws {
    let store = try HistoryStore(url: url)
    defer { try? store.close() }
    let folder = url.deletingLastPathComponent()
    let targets = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("targets.json"))) as! [String: String]
    let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("expected.json"))) as! [String: [String: String]]
    let start = ProcessInfo.processInfo.systemUptime
    let hold = try store.hold(node: targets["divergent"]!, kind: "state")
    let plan = try store.beginPlan(scope: "folio", target: targets["midpoint"]!)
    let result = try store.prune(targetGroups: 2_000)
    let early = try store.reconstruct(scope: "folio", node: targets["nearBeginning"]!)
    let divergent = try store.reconstruct(scope: "folio", node: targets["divergent"]!)
    guard early.state == expected["nearBeginning"], divergent.state == expected["divergent"] else {
        throw ProofError.gap("consolidated oracle mismatch")
    }
    let selected = try store.recoverSelected(scope: "folio", target: targets["divergent"]!, keys: ["branch-20"])
    guard try store.currentState(scope: "folio")["branch-20"] == expected["divergent"]?["branch-20"] else {
        throw ProofError.gap("selected material mismatch")
    }
    guard try store.references(store: "assets").contains(Resource(store: "assets", key: "shared", version: "1")) else {
        throw ProofError.gap("shared resource lost")
    }
    try store.releasePlan(plan)
    try store.releaseHold(hold)
    emit(["phase": "consolidation", "removed": result.removedGroups,
          "retained": result.retainedGroups, "unmet": result.unmetTarget,
          "earlyRecords": early.recordsVisited, "divergentRecords": divergent.recordsVisited,
          "selectedAction": selected, "seconds": seconds(start),
          "footprintBytes": try store.fileFootprint()])
}

@MainActor func reopen(url: URL) throws {
    let start = ProcessInfo.processInfo.systemUptime
    let store = try HistoryStore(url: url)
    defer { try? store.close() }
    let targetsData = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("targets.json"))
    let targets = try JSONSerialization.jsonObject(with: targetsData) as! [String: String]
    let scope = targets["scope"] ?? "folio"
    _ = try store.head(scope: scope)
    let available = seconds(start) * 1_000
    let pageStart = ProcessInfo.processInfo.systemUptime
    let page = try store.historyPage(scope: scope, offset: 0, count: 100)
    let pageTime = seconds(pageStart) * 1_000
    var planTime = 0.0; var planBytes = 0; var planAdvertised = 0; var planRecords = 0
    if let target = targets["midpoint"] ?? targets["nearBeginning"] ?? targets["end"] {
        let planStart = ProcessInfo.processInfo.systemUptime
        let plan = try store.beginPlan(scope: scope, target: target)
        let first = try store.planPage(plan, offset: 0, maxEntries: 100)
        planTime = seconds(planStart) * 1_000
        planBytes = first.bytesRead; planAdvertised = first.advertisedBytes
        planRecords = first.nodeIDs.count
        try store.releasePlan(plan)
    }
    emit(["phase": "reopen", "availabilityMs": available, "pageMs": pageTime,
          "pageCount": page.count, "firstPlanMs": planTime, "firstPlanBytes": planBytes, "firstPlanAdvertisedBytes": planAdvertised,
          "firstPlanRecords": planRecords])
}

@main @MainActor struct ScaleMain {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count >= 3 else { throw ProofError.refused("usage: fixture KIND URL SEED | reopen URL") }
            if args[1] == "fixture" {
                guard args.count == 5, let seed = UInt64(args[4]) else { throw ProofError.refused("fixture arguments") }
                try makeFixture(kind: args[2], url: URL(fileURLWithPath: args[3]), seed: seed)
            } else if args[1] == "reopen" {
                try reopen(url: URL(fileURLWithPath: args[2]))
            } else if args[1] == "consolidate" {
                try consolidate(url: URL(fileURLWithPath: args[2]))
            } else { throw ProofError.refused("unknown command") }
        } catch {
            emit(["phase": "error", "message": String(describing: error)])
            exit(1)
        }
    }
}
