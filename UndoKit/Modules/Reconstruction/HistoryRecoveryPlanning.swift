// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

@MainActor private enum RecoverySessions {
    static var plans: [ObjectIdentifier: [UUID: HistoryRecoveryPlan]] = [:]
}

extension HistoryEngine {
    /// Plans protect their sequence interval until explicit release or session close.
    /// The host captures the current domain baseline before requesting `.current`.
    public func beginRecoveryPlan(
        from source: HistoryRecoverySource = .current,
        to target: HistoryRecoveryTarget,
        using evidence: HistoryReconstructionEvidence
    ) throws -> HistoryRecoveryPlan {
        guard !closed, !closing, !draining, queue.isEmpty, !reconciling,
              !snapshot.isSuspended else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        _ = evidence // The explicit declaration is a host promise, never inferred from payload bytes.
        let scopeRow = try scopeRecord()
        let generation = try scopeRow.uuid("generationID")
        let version = scopeRow.int64("committedVersion")

        let targetSequence: Int64
        switch target {
        case .group(let id):
            guard let row = try fetchOne("HistoryGroupRecord", key: id.uuidString),
                  row.string("scopeKey") == scope.uuidString else {
                throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
            }
            targetSequence = row.int64("sequence")
        case .checkpoint(let id):
            guard let row = try fetchOne("HistoryCheckpointRecord", key: id.uuidString),
                  row.string("scopeKey") == scope.uuidString else {
                throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
            }
            targetSequence = row.int64("sequence")
        }

        // A checkpoint target is already a complete host-authored baseline.
        let effectiveSource: HistoryRecoverySource = {
            if case .checkpoint(let id) = target { return .checkpoint(id) }
            return source
        }()
        let baselineSequence: Int64
        let direction: HistoryRecoveryDirection
        switch effectiveSource {
        case .current:
            let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryGroupRecord")
            request.predicate = NSPredicate(format: "scopeKey == %@", scope.uuidString)
            request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: false)]
            request.fetchLimit = 1
            baselineSequence = try context.fetch(request).first?.int64("sequence") ?? 0
            direction = .reverse
            guard baselineSequence >= targetSequence else {
                throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
            }
        case .checkpoint(let id):
            guard let row = try fetchOne("HistoryCheckpointRecord", key: id.uuidString),
                  row.string("scopeKey") == scope.uuidString else {
                throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
            }
            baselineSequence = row.int64("sequence")
            direction = .forward
            guard baselineSequence <= targetSequence else {
                throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
            }
        }
        let lower = min(baselineSequence, targetSequence)
        let upper = max(baselineSequence, targetSequence)
        try rejectGap(lowerExclusive: lower, upperInclusive: upper)
        let plan = HistoryRecoveryPlan(id: UUID(), scope: scope, generation: generation,
            committedVersion: version, source: effectiveSource, target: target,
            baselineSequence: baselineSequence, targetSequence: targetSequence,
            direction: direction)
        RecoverySessions.plans[ObjectIdentifier(self), default: [:]][plan.id] = plan
        return plan
    }

    /// Reads at most `limit` accepted transitions; no host payload is materialized.
    public func recoveryPage(_ plan: HistoryRecoveryPlan, after cursor: Int64? = nil,
                             limit: Int) throws -> HistoryRecoveryPage {
        try requirePlan(plan)
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
    public func recoveryMaterial(_ plan: HistoryRecoveryPlan, groupID: UUID,
                                 ordinal: Int) throws -> HistoryRecoveryMaterial {
        try requirePlan(plan)
        guard let group = try fetchOne("HistoryGroupRecord", key: groupID.uuidString),
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
        guard case .checkpoint(let id) = plan.source else { return nil }
        return try checkpoint(id: id)
    }

    public func releaseRecoveryPlan(_ plan: HistoryRecoveryPlan) {
        RecoverySessions.plans[ObjectIdentifier(self)]?.removeValue(forKey: plan.id)
    }

    /// Called by store and scope closure; all handles from this session become invalid.
    func invalidateRecoveryPlans() {
        RecoverySessions.plans.removeValue(forKey: ObjectIdentifier(self))
    }

    /// #93 prunes against these intervals and their checkpoint baselines.
    var protectedRecoveryIntervals: [HistoryProtectedInterval] {
        guard !closed else { return [] }
        return (RecoverySessions.plans[ObjectIdentifier(self)] ?? [:]).values.map { plan in
            let checkpointID: UUID?
            if case .checkpoint(let id) = plan.source { checkpointID = id }
            else { checkpointID = nil }
            return HistoryProtectedInterval(
                lowerExclusiveSequence: min(plan.baselineSequence, plan.targetSequence),
                upperInclusiveSequence: max(plan.baselineSequence, plan.targetSequence),
                checkpointID: checkpointID)
        }
    }

    private func requirePlan(_ plan: HistoryRecoveryPlan) throws {
        guard !closed, !closing,
              RecoverySessions.plans[ObjectIdentifier(self)]?[plan.id] == plan else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
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
