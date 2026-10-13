// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import Foundation
import UndoKit

/// A public host workload boundary used by the command, device host and bounded test.
@MainActor public enum ScaleWorkload {
    /// Command-seam proof of uncertain host acceptance, separate from scale timings.
    public static func receiptWriteFailure(directory: URL, readback: Bool) async throws -> ScaleReceiptFailureReport {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = try ScaleHost(directory: directory, seed: 11, closeBeforeFirstSynchronization: !readback)
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
            scope: identifier(11, 1, 1), workingIdentity: identifier(11, 1, 0),
            mode: readback ? .existing : .create, host: host)
        let command = HistoryCommand(id: identifier(11, 2, 11_111),
            fingerprint: Data("receipt-sync-failure".utf8), payload: scalePayload(17))
        if readback {
            guard case .accepted = await engine.submit(command) else {
                throw ScaleFailure.assertion("Fresh-process uncertain receipt was not reconciled")
            }
            let state = await host.snapshot()
            try require(state.value == 17 && state.deliveries == 1 && state.members == 1,
                        "Fresh-process uncertain receipt duplicated or lost host effects")
            try require(try engine.historyPage(limit: 10).count == 1 && !engine.snapshot.isSuspended,
                        "Fresh-process uncertain receipt did not finalize exactly one group")
            try await engine.close(); try await host.close()
            return ScaleReceiptFailureReport(initialResult: "accepted", retryResult: "accepted", reconciliationResult: "accepted", suspended: false,
                hostValue: state.value, deliveries: state.deliveries, members: state.members,
                processID: ProcessInfo.processInfo.processIdentifier)
        }
        guard case .failure(let initial) = await engine.submit(command), initial.cause == .unresolved else {
            throw ScaleFailure.assertion("Receipt synchronization fault did not leave an unresolved outcome")
        }
        guard case .failure(let reconciliation)? = await engine.reconcile(), reconciliation.cause == .unresolved else {
            throw ScaleFailure.assertion("Uncertain receipt lookup falsely rejected or accepted reconciliation")
        }
        guard case .failure(let retry) = await engine.submit(command), retry.cause == .unresolved else {
            throw ScaleFailure.assertion("Uncertain receipt lookup falsely rejected or accepted the retry")
        }
        try require(engine.snapshot.isSuspended, "Uncertain receipt did not suspend history")
        let state = await host.snapshot()
        try await engine.close(); try await host.close()
        return ScaleReceiptFailureReport(initialResult: "unresolved", retryResult: "unresolved", reconciliationResult: "unresolved", suspended: true,
            hostValue: state.value, deliveries: state.deliveries, members: state.members,
            processID: ProcessInfo.processInfo.processIdentifier)
    }

    public static func create(directory: URL, groups: Int, seed: Int, budgets: ScaleBudgets = .mac,
                              progress: @escaping @MainActor (String) -> Void = { _ in }) async throws -> ScaleWorkloadReport {
        try require((100...100_000).contains(groups) && (1...10_000).contains(seed), "Invalid scale fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(budgets).write(to: directory.appendingPathComponent("Budgets.json"), options: .atomic)
        let monitor = ScaleMonitor(directory: directory, budgets: budgets)
        try monitor.start(); defer { monitor.stop() }
        let host = try ScaleHost(directory: directory, seed: seed)
        let resource = host.resource
        let trunk = groups / 100
        let branchA = min(100, (groups - trunk) / 2)
        let split = trunk + branchA
        let branchB = groups - split
        try Data(repeating: 42, count: 4096).write(to: directory.appendingPathComponent("SharedResource.bin"))
        var store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
            workingIdentity: identifier(seed, 1, 0), mode: .create,
            limits: HistoryLimits(maxPayloadBytes: 512 * 1024, maxStoreBytes: 1024 * 1024 * 1024,
                                  maxUndoGroups: 100, maxReadPage: 64))
        var engine = try await store.openScope(identifier(seed, 1, 1), mode: .create, host: host)
        // Exercise the public capacity boundary without exhausting actual memory/disk.
        guard case .failure(let refusal) = await engine.submit(HistoryCommand(
            fingerprint: Data("over-configured-limit".utf8), payload: scalePayload(9, bytes: 512 * 1024 + 1))),
            refusal.cause == .capacity else { throw ScaleFailure.assertion("Oversized request was not refused at admission") }
        try require(await host.snapshot().deliveries == 0 && !engine.snapshot.isSuspended,
                    "Capacity refusal changed host content or suspended usable history")
        var phases: [String: Double] = [:]
        var small: [Double] = [], large: [Double] = [], inverse: [Double] = [], pages: [Double] = []
        var sizes: [Int] = []
        var first: HistoryReceipt?, tipA: UUID?, tipB: UUID?, ancestor: UUID?
        var actionCounts: [Int: Int] = [:]
        let constructionStart = monotonic()
        progress("fixture"); monitor.phase = "fixture"; monitor.ordinary = true
        for index in 1...groups {
            try monitor.check()
            if index == split + 1 {
                monitor.ordinary = false; progress("divergent Undo construction"); monitor.phase = "divergent Undo construction"
                let undoStart = monotonic()
                for _ in 0..<branchA {
                    let start = monotonic()
                    guard case .accepted = await engine.undo() else { throw ScaleFailure.assertion("Divergent Undo refused") }
                    inverse.append(monotonic() - start)
                    try monitor.check()
                }
                phases["branchUndoConstruction"] = monotonic() - undoStart
                try require(await host.snapshot().value == seed * 100_000 + trunk * 2, "Ancestor host value mismatch")
                monitor.ordinary = true; monitor.phase = "fixture branch B"; progress("fixture branch B")
            }
            let command = scaleCommand(seed: seed, index: index)
            let start = monotonic()
            guard case .accepted(let receipt) = await engine.submit(command) else {
                throw ScaleFailure.assertion("Fixture group \(index) refused")
            }
            let seconds = monotonic() - start
            if index.isMultiple(of: 997) { large.append(seconds) } else { small.append(seconds) }
            actionCounts[command.members.count, default: 0] += 1
            // Three complete encodings: input plus both accepted effects; host padding is fixed per member.
            sizes.append(command.members.reduce(0) { $0 + $1.payload.data.count * 3 })
            if index == 1 { first = receipt }
            if index == trunk {
                ancestor = try engine.createCheckpoint(name: "Shared ancestor", state: scalePayload(seed * 100_000 + trunk * 2),
                                                        resources: [resource]).id
            }
            if index == split { tipA = receipt.groupID }
            if index == groups { tipB = receipt.groupID }
            if index.isMultiple(of: 64) { await Task.yield() }
        }
        phases["constructionIncludingUndo"] = monotonic() - constructionStart
        monitor.ordinary = false
        guard let first, let tipA, let tipB, let ancestor else { throw ScaleFailure.assertion("Missing fixture endpoint") }
        let expectedCurrent = seed * 100_000 + groups * 2
        try require(await host.snapshot().value == expectedCurrent, "Fixture final host value mismatch")
        progress("farBack"); monitor.phase = "farBack"
        let far = try await reconstruct(engine, target: .group(first.groupID), current: expectedCurrent, monitor: monitor)
        try require(far.value == seed * 100_000 + 2 && far.recordsVisited == groups + branchA - 1,
                    "Far-back reconstruction differs from independent topology/state")
        progress("divergent"); monitor.phase = "divergent"
        let divergent = try await reconstruct(engine, target: .group(tipA), current: expectedCurrent, monitor: monitor)
        try require(divergent.value == seed * 100_000 + split * 2 && divergent.recordsVisited == branchA + branchB,
                    "Divergent reconstruction differs from independent topology/state")
        try require(await host.snapshot().value == expectedCurrent, "Reconstruction changed current content")
        let restoreA = HistoryCommand(fingerprint: Data("restore-A".utf8), payload: scalePayload(divergent.value), restorationOrigin: tipA)
        guard case .accepted = await engine.submit(restoreA) else { throw ScaleFailure.assertion("Restore A refused") }
        let returned = try await reconstruct(engine, target: .group(tipB), current: divergent.value, monitor: monitor)
        try require(returned.value == expectedCurrent && returned.recordsVisited == 1, "Return to displaced B mismatch")
        guard case .accepted = await engine.submit(HistoryCommand(fingerprint: Data("restore-B".utf8),
            payload: scalePayload(returned.value), restorationOrigin: tipB)) else { throw ScaleFailure.assertion("Restore B refused") }
        let heldFirst = try engine.holdDetail(from: first.groupID, through: first.groupID)
        let heldA = try engine.holdDetail(from: tipA, through: tipA)
        let heldState = try engine.holdState(ancestor)
        let checkpoint = try engine.createCheckpoint(name: "Current B", state: scalePayload(expectedCurrent), resources: [resource])
        // Reopening with the ordinary 100-group allowance makes older detailed history eligible for maintenance.
        try await store.close()
        store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
            workingIdentity: identifier(seed, 1, 0), mode: .existing,
            limits: HistoryLimits(maxPayloadBytes: 512 * 1024, maxStoreBytes: 1024 * 1024 * 1024, maxUndoGroups: min(100, groups / 10), maxReadPage: 64))
        engine = try await store.openScope(identifier(seed, 1, 1), mode: .existing, host: host)
        progress("retention"); monitor.phase = "retention"
        let retentionStart = monotonic()
        var removed = 0, passes = 0
        while true {
            try monitor.check()
            let result = try engine.consolidateHistory(through: checkpoint.id, policy: HistoryRetentionPolicy(targetDetailedGroups: min(100, groups / 10)))
            removed += result.removedGroups; passes += 1
            if !result.hasMore { break }
            try require(passes < groups * 2, "Retention did not make bounded progress")
            await Task.yield()
        }
        try require(removed > 0, "No eligible detail consolidated")
        phases["retention"] = monotonic() - retentionStart
        let expectedIDs = [first.groupID, tipA, tipB]
        let retained = try historyIDs(engine, timings: &pages)
        try require(Set(expectedIDs).isSubset(of: Set(retained)), "Protected/displaced detail lost")
        try verifyProtectedMembers(engine, expected: [first.groupID: 1, tipA: split.isMultiple(of: 10) ? 2 : 1,
                                                     tipB: groups.isMultiple(of: 10) ? 2 : 1])
        try require(try engine.checkpoint(id: ancestor)?.state == scalePayload(seed * 100_000 + trunk * 2), "Held ancestor state lost")
        try require(try engine.checkpoint(id: checkpoint.id)?.state == scalePayload(expectedCurrent), "Current checkpoint changed")
        let protectedResources = try store.requiredObjects(in: resource.storeID, limit: 64)
        try require(protectedResources.objects.contains { $0.reference == resource && $0.referenceCount >= 2 }, "Shared retained resource lost")
        let baseline = try await reconstruct(engine, target: .checkpoint(ancestor), current: expectedCurrent, monitor: monitor)
        try require(baseline.value == seed * 100_000 + trunk * 2 && baseline.recordsVisited == 0,
                    "Checkpoint baseline reconstruction differs from independent state")
        let beforeRetry = await host.snapshot()
        try require(await engine.submit(scaleCommand(seed: seed, index: 1)) == .accepted(first), "First Command retry identity lost")
        try require(await host.snapshot().deliveries == beforeRetry.deliveries, "First Command retry duplicated acceptance")
        let expectedDeliveries = groups + branchA + 2
        let submittedMembers = groups + groups / 10
        let inverseMembers = branchA + split / 10 - trunk / 10
        let state = await host.snapshot()
        try require(state.value == expectedCurrent && state.deliveries == expectedDeliveries &&
                    state.members == submittedMembers + inverseMembers + 2, "Host effects differ from independent workload ledger")
        let manifest = ScaleManifest(seed: seed, groups: groups, firstGroup: first.groupID, branchAGroup: tipA,
            branchBGroup: tipB, firstReceiptSequence: first.token.sequence, firstReceiptGeneration: first.token.generation,
            ancestorCheckpoint: ancestor, currentCheckpoint: checkpoint.id, holdIDs: [heldFirst.id, heldA.id, heldState.id],
            expectedValue: expectedCurrent, expectedDeliveries: expectedDeliveries,
            expectedMembers: submittedMembers + inverseMembers + 2, expectedRetainedIDs: expectedIDs)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("Manifest.json"), options: .atomic)
        try await store.close(); try await host.close(); try monitor.sample()
        try require(monitor.maximumOrdinaryGap <= budgets.ordinaryHeartbeatSeconds, "Ordinary main-actor heartbeat exceeded declared budget")
        let disk = diskComponents(directory)
        phases["total"] = monotonic() - monitor.started
        return ScaleWorkloadReport(seed: seed, groups: groups, trunkGroups: trunk, branchAGroups: branchA, branchBGroups: branchB,
            actionsPerGroup: actionCounts, encodedBytes: sizes.reduce(0, +), groupEncodedByteSizes: sizes,
            allAcceptedEncodedPayloadBytes: state.encodedPayloadBytes, controlledLimitRefusalVerified: true, phases: phases,
            ordinarySubmission: ScaleDistribution(small), largeSubmission: ScaleDistribution(large), inverse: ScaleDistribution(inverse),
            historyPages: ScaleDistribution(pages), hostDelivery: ScaleDistribution(await host.timings()),
            farBack: far, divergent: divergent, returnToDisplaced: returned,
            checkpointBaseline: baseline, removedGroups: removed, consolidationPasses: passes, hostValue: state.value,
            peakResidentBytes: monitor.peakResident, peakOwnedAllocatedBytes: monitor.peakOwned,
            historyAllocatedBytes: disk.history, hostAllocatedBytes: disk.host, maximumOrdinaryHeartbeatGapSeconds: monitor.maximumOrdinaryGap,
            processID: ProcessInfo.processInfo.processIdentifier, hardware: hardwareIdentifier(), os: ProcessInfo.processInfo.operatingSystemVersionString,
            platform: platformIdentity, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    public static func reopen(directory: URL, budgets: ScaleBudgets = .mac) async throws -> ScaleReopenReport {
        let start = monotonic()
        let manifest = try JSONDecoder().decode(ScaleManifest.self, from: Data(contentsOf: directory.appendingPathComponent("Manifest.json")))
        let monitor = ScaleMonitor(directory: directory, budgets: budgets); try monitor.start(); defer { monitor.stop() }
        let host = try ScaleHost(directory: directory, seed: manifest.seed)
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
            workingIdentity: identifier(manifest.seed, 1, 0), mode: .existing,
            limits: HistoryLimits(maxPayloadBytes: 512 * 1024, maxStoreBytes: 1024 * 1024 * 1024, maxUndoGroups: min(100, manifest.groups / 10), maxReadPage: 64))
        let engine = try await store.openScope(identifier(manifest.seed, 1, 1), mode: .existing, host: host)
        let availability = monotonic() - start
        let snapshot = engine.snapshot
        let state = await host.snapshot()
        try require(state.value == manifest.expectedValue && state.deliveries == manifest.expectedDeliveries &&
                    state.members == manifest.expectedMembers && snapshot.canUndo && !snapshot.canRedo && !snapshot.isSuspended,
                    "Fresh-process host content/effects/availability mismatch")
        var timings: [Double] = []
        try require(Set(manifest.expectedRetainedIDs).isSubset(of: Set(try historyIDs(engine, timings: &timings))), "Fresh-process protected history lost")
        let split = manifest.groups / 100 + min(100, (manifest.groups - manifest.groups / 100) / 2)
        try verifyProtectedMembers(engine, expected: [manifest.firstGroup: 1, manifest.branchAGroup: split.isMultiple(of: 10) ? 2 : 1,
                                                     manifest.branchBGroup: manifest.groups.isMultiple(of: 10) ? 2 : 1])
        try require(Set(try engine.retentionHolds().map(\.id)) == Set(manifest.holdIDs), "Fresh-process holds changed")
        let trunk = manifest.groups / 100
        try require(try engine.checkpoint(id: manifest.ancestorCheckpoint)?.state == scalePayload(manifest.seed * 100_000 + trunk * 2), "Fresh-process ancestor checkpoint changed")
        try require(try engine.checkpoint(id: manifest.currentCheckpoint)?.state == scalePayload(manifest.expectedValue), "Fresh-process current checkpoint changed")
        let resource = host.resource
        try require(try store.requiredObjects(in: resource.storeID, limit: 64).objects.contains { $0.reference == resource }, "Fresh-process resource reference lost")
        try require(try Data(contentsOf: directory.appendingPathComponent("SharedResource.bin")) == Data(repeating: 42, count: 4096), "Host resource bytes changed")
        guard case .accepted(let receipt) = await engine.submit(scaleCommand(seed: manifest.seed, index: 1)) else { throw ScaleFailure.assertion("Fresh-process retry refused") }
        try require(receipt.groupID == manifest.firstGroup && receipt.token.sequence == manifest.firstReceiptSequence &&
                    receipt.token.generation == manifest.firstReceiptGeneration, "Fresh-process first receipt identity changed")
        try require(await host.snapshot().deliveries == manifest.expectedDeliveries, "Fresh-process retry duplicated effects")
        try await store.close(); try await host.close(); try monitor.sample()
        let disk = diskComponents(directory)
        return ScaleReopenReport(hostValue: state.value, deliveries: state.deliveries, members: state.members,
            availabilitySeconds: availability, totalSeconds: monotonic() - start, processID: ProcessInfo.processInfo.processIdentifier,
            canUndo: snapshot.canUndo, canRedo: snapshot.canRedo, peakResidentBytes: monitor.peakResident,
            peakOwnedAllocatedBytes: monitor.peakOwned, historyAllocatedBytes: disk.history, hostAllocatedBytes: disk.host)
    }

    private static func historyIDs(_ engine: HistoryEngine, timings: inout [Double]) throws -> [UUID] {
        var ids: [UUID] = [], cursor: Int64?
        while true {
            let start = monotonic(); let page = try engine.historyPage(after: cursor, limit: 64); timings.append(monotonic() - start)
            ids.append(contentsOf: page.map(\.groupID))
            guard let last = page.last else { return ids }; cursor = last.sequence
        }
    }
    private static func verifyProtectedMembers(_ engine: HistoryEngine, expected: [UUID: Int]) throws {
        var cursor: Int64?
        var verified = Set<UUID>()
        while true {
            let page = try engine.historyPage(after: cursor, limit: 64)
            for entry in page {
                if let members = expected[entry.groupID] {
                    try require(entry.memberCount == members, "Protected Undo Group lost complete members")
                    verified.insert(entry.groupID)
                }
            }
            guard let last = page.last else { break }; cursor = last.sequence
        }
        try require(verified == Set(expected.keys), "Protected group missing")
    }
    private static func reconstruct(_ engine: HistoryEngine, target: HistoryRecoveryTarget, current: Int,
                                    monitor: ScaleMonitor) async throws -> ScaleReconstruction {
        let start = monotonic(); let plan = try engine.beginRecoveryPlan(to: target, using: .acceptedEffects)
        defer { engine.releaseRecoveryPlan(plan) }
        var value = current, records = 0, bytes = 0, cursor: Int64?, firstResponse = 0.0
        if let checkpoint = try engine.recoveryCheckpoint(plan) { value = try decodeState(checkpoint.state.data); bytes += checkpoint.state.data.count }
        repeat {
            try monitor.check()
            let page = try engine.recoveryPage(plan, after: cursor, limit: 64)
            if records == 0 { firstResponse = monotonic() - start }
            for step in page.steps {
                let ordinals = plan.direction == .reverse ? Array((0..<step.memberCount).reversed()) : Array(0..<step.memberCount)
                for ordinal in ordinals {
                    let material = try engine.recoveryMaterial(plan, groupID: step.groupID, ordinal: ordinal)
                    value = try decodeState(material.payload.data); bytes += material.payload.data.count
                }
                records += 1
            }
            cursor = page.nextCursor; await Task.yield()
        } while cursor != nil
        return ScaleReconstruction(value: value, recordsVisited: records, bytesRead: bytes,
                                   firstResponseSeconds: firstResponse, seconds: monotonic() - start)
    }
    private static func hardwareIdentifier() -> String {
        var system = utsname(); uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }
    private static var platformIdentity: String {
        #if targetEnvironment(simulator)
        return "iOS Simulator (smoke only)"
        #elseif os(iOS)
        return "physical iOS"
        #else
        return "macOS"
        #endif
    }
}
