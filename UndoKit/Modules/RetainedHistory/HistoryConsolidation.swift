// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension RetainedHistory {
    func consolidateHistory(through checkpointID: UUID,
                            policy: HistoryRetentionPolicy) throws -> HistoryConsolidationResult {
        try activity.requireIdle()
        guard policy.targetDetailedGroups >= 0,
              let boundary = try checkpoint(id: checkpointID) else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        try checkKeptCheckpoints(policy.keptCheckpointIDs)
        guard !Task.isCancelled else {
            throw HistoryFailure(.cancelled, stage: .admission, disposition: .usable)
        }
        let groups = try history.fetch(HistoryGroupRecord.self, predicate: NSPredicate(
            format: "\(#keyPath(HistoryGroupRecord.scopeKey)) == %@", scope.uuidString),
            sort: [NSSortDescriptor(key: #keyPath(HistoryGroupRecord.sequence), ascending: false)])
        let protected = try protectedGroupKeys(groups: groups,
            targetDetailedGroups: policy.targetDetailedGroups)
        let candidates = groups.filter {
            $0.sequence < boundary.info.sequence &&
            !protected.contains($0.key ?? "")
        }
        let holds = try retentionHolds()
        var keptCheckpoints = policy.keptCheckpointIDs
        keptCheckpoints.insert(checkpointID)
        for hold in holds {
            if case .state(let id) = hold.kind { keptCheckpoints.insert(id) }
        }
        for plan in activeRecoveryPlans {
            if case .checkpoint(let id) = plan.source { keptCheckpoints.insert(id) }
            if case .checkpoint(let id) = plan.target { keptCheckpoints.insert(id) }
        }
        let checkpoints = try history.fetch(HistoryCheckpointRecord.self, predicate: NSPredicate(
            format: "\(#keyPath(HistoryCheckpointRecord.scopeKey)) == %@ AND \(#keyPath(HistoryCheckpointRecord.sequence)) < %@", scope.uuidString,
            NSNumber(value: boundary.info.sequence)))
        let removableCheckpoints = checkpoints.filter {
            guard let id = $0.key.flatMap(UUID.init(uuidString:)) else { return false }
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
                    ownerKey: history.transactionKey(try row.uuid(row.key)))
                context.delete(row)
            }
            if !selectedGroups.isEmpty || !selectedCheckpoints.isEmpty {
                let scopeRow = try history.scopeRecord()
                scopeRow.committedVersion += 1
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
