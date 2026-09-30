// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryEngine {
    /// Plans protect their sequence interval until explicit release or session close.
    /// The host captures the current domain baseline before requesting `.current`.
    /// - Parameters:
    ///   - source: Coherent current domain state or a stored checkpoint baseline.
    ///   - target: Accepted group state or complete checkpoint to reconstruct.
    ///   - evidence: Explicit host promise that accepted effects represent state transitions.
    /// - Returns: A session-bound handle; release it on success, failure or abandonment.
    /// - Throws: Busy/suspended scope, plan capacity, cancellation, missing target or retained gap.
    public func beginRecoveryPlan(
        from source: HistoryRecoverySource = .current,
        to target: HistoryRecoveryTarget,
        using evidence: HistoryReconstructionEvidence
    ) throws -> HistoryRecoveryPlan {
        guard !closed, !closing, !draining, queue.isEmpty, !reconciling,
              !snapshot.isSuspended else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        guard recoveryPlans.count < limits.maxRecoveryPlans else {
            throw HistoryFailure(.capacity, stage: .admission, disposition: .usable)
        }
        try checkRecoveryCancellation()
        _ = evidence // The explicit declaration is a host promise, never inferred from payload bytes.
        let scopeRow = try scopeRecord()
        let generation = try scopeRow.uuid("generationID")
        let version = scopeRow.int64("committedVersion")

        let targetSequence = try recoveryTargetSequence(target)

        if source == .current, case .group = target,
           !scopeRow.bool("recordingEnabled") ||
           (scopeRow.int64("currentBaselineSequence") > 0 &&
            targetSequence < scopeRow.int64("currentBaselineSequence")) {
            throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
        }

        // A checkpoint target is already a complete host-authored baseline.
        let effectiveSource: HistoryRecoverySource = {
            if case .checkpoint(let id) = target { return .checkpoint(id) }
            return source
        }()
        let (baselineSequence, direction) = try recoveryBaseline(effectiveSource, target: targetSequence)
        let baselineAccepted = try recoveryAcceptedSequence(effectiveSource)
        let targetAccepted: Int64
        if case .checkpoint = target { targetAccepted = baselineAccepted } else { targetAccepted = targetSequence }
        let lower = min(baselineSequence, targetSequence)
        let upper = max(baselineSequence, targetSequence)
        try rejectGap(lowerExclusive: lower, upperInclusive: upper)
        let plan = HistoryRecoveryPlan(id: UUID(), scope: scope, generation: generation,
            committedVersion: version, source: effectiveSource, target: target,
            baselineSequence: baselineSequence, targetSequence: targetSequence,
            direction: direction, baselineAcceptedSequence: baselineAccepted,
            targetAcceptedSequence: targetAccepted)
        recoveryPlans[plan.id] = plan
        return plan
    }

    /// Reads at most `limit` accepted transitions; no host payload is materialized.
    /// Pass only the preceding page's cursor for this handle. Throws for an invalid
    /// handle/cursor, limit, missing interval or cancellation. Cancellation releases
    /// the handle. Nil `nextCursor` means this traversal is complete.
    public func recoveryPage(_ plan: HistoryRecoveryPlan, after cursor: Int64? = nil,
                             limit: Int) throws -> HistoryRecoveryPage {
        try requirePlan(plan)
        try checkRecoveryCancellation(plan)
        guard limit > 0, limit <= limits.maxReadPage else {
            throw HistoryFailure(.capacity, stage: .admission, disposition: .usable)
        }
        let lower = min(plan.baselineSequence, plan.targetSequence)
        let upper = max(plan.baselineSequence, plan.targetSequence)
        try rejectGap(lowerExclusive: lower, upperInclusive: upper)
        let start = cursor ?? plan.baselineSequence
        guard start >= lower, start <= upper else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        let forward = plan.direction == .forward
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryGroupRecord")
        if forward {
            request.predicate = NSPredicate(format: "scopeKey == %@ AND sequence > %@ AND sequence <= %@",
                scope.uuidString, NSNumber(value: start), NSNumber(value: upper))
        } else if cursor == nil {
            request.predicate = NSPredicate(format: "scopeKey == %@ AND sequence <= %@ AND sequence > %@",
                scope.uuidString, NSNumber(value: upper), NSNumber(value: lower))
        } else {
            request.predicate = NSPredicate(format: "scopeKey == %@ AND sequence < %@ AND sequence > %@",
                scope.uuidString, NSNumber(value: start), NSNumber(value: lower))
        }
        request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: forward)]
        request.fetchLimit = limit + 1
        let rows = try context.fetch(request)
        let pageRows = Array(rows.prefix(limit))
        try validateRecoveryChain(plan, rows: pageRows, after: cursor, exhausted: rows.count <= limit)
        let steps = try pageRows.map { row in
            HistoryRecoveryStep(groupID: try row.uuid("key"), sequence: row.int64("sequence"),
                memberCount: Int(row.int64("memberCount")),
                kind: HistoryEntryKind(rawValue: row.string("kind") ?? "") ?? .command,
                restorationOrigin: row.string("restorationOrigin").flatMap(UUID.init(uuidString:)))
        }
        return HistoryRecoveryPage(steps: steps,
            nextCursor: rows.count > limit ? steps.last?.sequence : nil)
    }

    /// Fetches one intact opaque accepted-effect member from a plan step.
    /// `groupID` and `ordinal` must identify a member in this plan's interval.
    /// Throws on missing/corrupt material, invalid selection or cancellation;
    /// it never invokes the host or mutates live state.
    public func recoveryMaterial(_ plan: HistoryRecoveryPlan, groupID: UUID,
                                 ordinal: Int) throws -> HistoryRecoveryMaterial {
        try requirePlan(plan)
        try checkRecoveryCancellation(plan)
        guard let group = try scopedRow("HistoryGroupRecord", id: groupID),
              group.string("scopeKey") == scope.uuidString,
              ordinal >= 0, Int64(ordinal) < group.int64("memberCount") else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        let sequence = group.int64("sequence")
        let lower = min(plan.baselineSequence, plan.targetSequence)
        let upper = max(plan.baselineSequence, plan.targetSequence)
        guard sequence > lower, sequence <= upper else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        try rejectGap(lowerExclusive: lower, upperInclusive: upper)
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryActionRecord")
        request.predicate = NSPredicate(format: "group == %@ AND ordinal == %@",
                                        group, NSNumber(value: ordinal))
        request.fetchLimit = 1
        guard let row = try context.fetch(request).first else {
            throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
        }
        let prefix = plan.direction == .reverse ? "undo" : "redo"
        return HistoryRecoveryMaterial(memberID: try row.uuid("memberID"), ordinal: ordinal,
                                       payload: try payload(on: row, prefix: prefix))
    }

    /// Returns a checkpoint baseline only if it belongs to this live plan.
    public func recoveryCheckpoint(_ plan: HistoryRecoveryPlan) throws -> HistoryCheckpoint? {
        try requirePlan(plan)
        try checkRecoveryCancellation(plan)
        guard case .checkpoint(let id) = plan.source else { return nil }
        guard let value = try checkpoint(id: id) else {
            throw HistoryFailure(.missingHistory, stage: .reconciliation, disposition: .usable)
        }
        return value
    }

    /// Ends temporary retention protection. Releasing an already-ended handle is harmless.
    public func releaseRecoveryPlan(_ plan: HistoryRecoveryPlan) {
        recoveryPlans.removeValue(forKey: plan.id)
    }

    /// Stops further reads and relinquishes temporary protection immediately.
    public func cancelRecoveryPlan(_ plan: HistoryRecoveryPlan) {
        releaseRecoveryPlan(plan)
    }

    /// Called by store and scope closure; all handles from this session become invalid.
    func invalidateRecoveryPlans() {
        recoveryPlans.removeAll()
    }

    private func recoveryTargetSequence(_ target: HistoryRecoveryTarget) throws -> Int64 {
        let entity: String
        let id: UUID
        switch target {
        case .group(let value): entity = "HistoryGroupRecord"; id = value
        case .checkpoint(let value): entity = "HistoryCheckpointRecord"; id = value
        }
        guard let row = try scopedRow(entity, id: id) else {
            throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
        }
        return row.int64("sequence")
    }

    private func recoveryBaseline(_ source: HistoryRecoverySource, target: Int64)
        throws -> (Int64, HistoryRecoveryDirection) {
        switch source {
        case .current:
            let sequence = try scopeRecord().int64("latestAcceptedSequence")
            guard sequence >= target else {
                throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
            }
            return (sequence, .reverse)
        case .checkpoint(let id):
            guard let row = try scopedRow("HistoryCheckpointRecord", id: id) else {
                throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
            }
            let sequence = row.int64("sequence")
            guard sequence <= target else {
                throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
            }
            return (sequence, .forward)
        }
    }

    private func requirePlan(_ plan: HistoryRecoveryPlan) throws {
        guard !closed, !closing,
              recoveryPlans[plan.id] == plan else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
    }

    private func checkRecoveryCancellation() throws {
        if Task.isCancelled {
            throw HistoryFailure(.cancelled, stage: .admission, disposition: .usable)
        }
    }

    private func checkRecoveryCancellation(_ plan: HistoryRecoveryPlan) throws {
        if Task.isCancelled {
            releaseRecoveryPlan(plan)
            throw HistoryFailure(.cancelled, stage: .admission, disposition: .usable)
        }
    }

    private func scopedRow(_ name: String, id: UUID) throws -> NSManagedObject? {
        try fetch(name, predicate: NSPredicate(format: "scopeKey == %@ AND key == %@",
            scope.uuidString, id.uuidString)).first
    }

    private func rejectGap(lowerExclusive lower: Int64, upperInclusive upper: Int64) throws {
        guard upper > lower else { return }
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryGapRecord")
        request.predicate = NSPredicate(
            format: "scopeKey == %@ AND lowerExclusiveSequence < %@ AND upperInclusiveSequence > %@",
            scope.uuidString, NSNumber(value: upper), NSNumber(value: lower))
        request.fetchLimit = 1
        if try !context.fetch(request).isEmpty {
            throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
        }
    }
}
