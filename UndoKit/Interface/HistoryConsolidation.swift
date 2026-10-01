// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryEngine {
    /// Replaces eligible accepted detail before a host-confirmed checkpoint.
    /// Each call removes at most maxReadPage groups and checkpoints in one store
    /// transaction. The checkpoint carries the coherent state; no command replay
    /// or synthetic state inference occurs here.
    /// The scope must be idle and writable. Active plans, holds, current state
    /// identity, and the configured ordinary Undo/Redo depth stay protected.
    /// `targetUnmet` reports retained group count above the policy target;
    /// `hasMore` means another bounded pass can remove eligible material.
    /// Repeated calls may scan retained group metadata and can be expensive.
    /// Cancellation before commit rolls back that pass. A save failure suspends
    /// the physical store; inspect and reopen it before retrying. Removed
    /// resource references leave durable host cleanup work for
    /// `HistoryStore.withRequiredObjects(in:cleanup:)`.
    public func consolidateHistory(through checkpointID: UUID,
                                   policy: HistoryRetentionPolicy) throws -> HistoryConsolidationResult {
        try transaction.requireIdle()
        guard policy.targetDetailedGroups >= 0,
              let boundary = try checkpoint(id: checkpointID) else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        try checkKeptCheckpoints(policy.keptCheckpointIDs)
        guard !Task.isCancelled else {
            throw HistoryFailure(.cancelled, stage: .admission, disposition: .usable)
        }
        let groups = try history.fetch("HistoryGroupRecord", predicate: NSPredicate(
            format: "scopeKey == %@", scope.uuidString),
            sort: [NSSortDescriptor(key: "sequence", ascending: false)])
        let protected = try protectedGroupKeys(groups: groups,
            targetDetailedGroups: policy.targetDetailedGroups)
        let candidates = groups.filter {
            $0.int64("sequence") < boundary.info.sequence &&
            !protected.contains($0.string("key") ?? "")
        }
        let holds = try retentionHolds()
        var keptCheckpoints = policy.keptCheckpointIDs
        keptCheckpoints.insert(checkpointID)
        for hold in holds {
            if case .state(let id) = hold.kind { keptCheckpoints.insert(id) }
        }
        for plan in history.recoveryPlans.values {
            if case .checkpoint(let id) = plan.source { keptCheckpoints.insert(id) }
            if case .checkpoint(let id) = plan.target { keptCheckpoints.insert(id) }
        }
        let checkpoints = try history.fetch("HistoryCheckpointRecord", predicate: NSPredicate(
            format: "scopeKey == %@ AND sequence < %@", scope.uuidString,
            NSNumber(value: boundary.info.sequence)))
        let removableCheckpoints = checkpoints.filter {
            guard let id = $0.string("key").flatMap(UUID.init(uuidString:)) else { return false }
            return !keptCheckpoints.contains(id)
        }
        let selectedGroups = Array(candidates.prefix(limits.maxReadPage))
        let remaining = max(0, limits.maxReadPage - selectedGroups.count)
        let selectedCheckpoints = Array(removableCheckpoints.prefix(remaining))
        do {
            for group in selectedGroups {
                if Task.isCancelled {
                    throw HistoryFailure(.cancelled, stage: .admission, disposition: .usable)
                }
                try retireAcceptedGroup(group)
            }
            for row in selectedCheckpoints {
                try history.removeResourceReferences(ownerType: "checkpoint",
                    ownerKey: history.transactionKey(try row.uuid("key")))
                context.delete(row)
            }
            if !selectedGroups.isEmpty || !selectedCheckpoints.isEmpty {
                let scopeRow = try history.scopeRecord()
                scopeRow.setValue(scopeRow.int64("committedVersion") + 1, forKey: "committedVersion")
                try history.saveRetention()
            }
        } catch {
            context.rollback()
            throw error
        }
        let retained = groups.count - selectedGroups.count
        return HistoryConsolidationResult(removedGroups: selectedGroups.count,
            removedCheckpoints: selectedCheckpoints.count,
            protectedGroups: protected.count, retainedGroups: retained,
            targetUnmet: retained > policy.targetDetailedGroups,
            hasMore: candidates.count > selectedGroups.count ||
                removableCheckpoints.count > selectedCheckpoints.count)
    }

}
