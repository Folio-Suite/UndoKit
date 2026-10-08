// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension RetainedHistory {
    func checkKeptCheckpoints(_ ids: Set<UUID>) throws {
        for id in ids where try checkpoint(id: id) == nil {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
    }

    func protectedGroupKeys(groups: [HistoryGroupRecord],
                            targetDetailedGroups: Int) throws -> Set<String> {
        var kept = Set(groups.prefix(targetDetailedGroups).compactMap { $0.key })
        // The latest accepted transition is the current structural endpoint
        // even when ordinary eligibility has changed independently.
        if let latest = groups.first?.key { kept.insert(latest) }
        kept.formUnion(groups.filter { $0.kind == "command" &&
            $0.state != "branched" }.prefix(limits.maxUndoGroups)
            .compactMap { $0.key })
        let holds = try retentionHolds()
        for hold in holds {
            if case .detail(let first, let last) = hold.kind {
                kept.formUnion(groups.filter { $0.sequence >= first &&
                    $0.sequence <= last }.compactMap { $0.key })
            }
        }
        for plan in activeRecoveryPlans {
            let lower = min(plan.baselineSequence, plan.targetSequence)
            let upper = max(plan.baselineSequence, plan.targetSequence)
            kept.formUnion(groups.filter { $0.sequence > lower &&
                $0.sequence <= upper }.compactMap { $0.key })
            // Reverse reconstruction omits the target effect from its steps.
            // Its historical endpoint still has to survive the live plan.
            if case .group(let id) = plan.target { kept.insert(id.uuidString) }
        }
        // Keep structural partners of protected Undo/Redo actions, including
        // an original on a displaced branch and its compensation relation.
        var changed = true
        while changed {
            let before = kept.count
            for group in groups {
                let key = group.key ?? ""
                let source = group.sourceGroupID
                let compensation = group.compensationGroupID
                if kept.contains(key) {
                    if let source { kept.insert(source) }
                    if let compensation { kept.insert(compensation) }
                } else if source.map(kept.contains) == true || compensation.map(kept.contains) == true {
                    kept.insert(key)
                }
            }
            changed = kept.count != before
        }
        return kept.intersection(Set(groups.compactMap { $0.key }))
    }

    func retireAcceptedGroup(_ group: HistoryGroupRecord) throws {
        let groupID = try group.uuid(group.key)
        let transactionKey = history.transactionKey(groupID)
        guard let transaction = try history.fetchOne(HistoryTransactionRecord.self, keyPath: \.key, key: transactionKey),
              transaction.stage == "accepted" else {
            throw HistoryFailure(.storage, stage: .finalization, disposition: .suspended)
        }
        let retired = history.insert(HistoryRetiredCommandRecord.self)
        retired.key = transactionKey
        retired.scopeKey = scope.uuidString
        retired.generationID = transaction.generationID
        retired.commandID = transaction.commandID
        retired.fingerprint = transaction.fingerprint
        retired.sequence = transaction.sequence
        retired.groupID = groupID.uuidString
        for action in try history.fetch(HistoryActionRecord.self, predicate: NSPredicate(
            format: "\(#keyPath(HistoryActionRecord.group)) == %@", group)) {
            try history.removeResourceReferences(ownerType: "action", ownerKey: action.key ?? "")
        }
        let gap = history.insert(HistoryGapRecord.self)
        gap.key = UUID().uuidString
        gap.scopeKey = scope.uuidString
        gap.generationID = transaction.generationID
        gap.lowerExclusiveSequence = group.sequence - 1
        gap.upperInclusiveSequence = group.sequence
        context.delete(group)
        context.delete(transaction)
    }
}
