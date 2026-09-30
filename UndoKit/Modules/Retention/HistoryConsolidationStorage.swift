// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryEngine {
    func checkKeptCheckpoints(_ ids: Set<UUID>) throws {
        for id in ids where try checkpoint(id: id) == nil {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
    }

    func protectedGroupKeys(groups: [NSManagedObject],
                                    targetDetailedGroups: Int) throws -> Set<String> {
        var kept = Set(groups.prefix(targetDetailedGroups).compactMap { $0.string("key") })
        // The latest accepted transition is the current structural endpoint
        // even when ordinary eligibility has changed independently.
        if let latest = groups.first?.string("key") { kept.insert(latest) }
        kept.formUnion(groups.filter { $0.string("kind") == "command" &&
            $0.string("state") != "branched" }.prefix(limits.maxUndoGroups)
            .compactMap { $0.string("key") })
        let holds = try retentionHolds()
        for hold in holds {
            if case .detail(let first, let last) = hold.kind {
                kept.formUnion(groups.filter { $0.int64("sequence") >= first &&
                    $0.int64("sequence") <= last }.compactMap { $0.string("key") })
            }
        }
        for plan in recoveryPlans.values {
            let lower = min(plan.baselineSequence, plan.targetSequence)
            let upper = max(plan.baselineSequence, plan.targetSequence)
            kept.formUnion(groups.filter { $0.int64("sequence") > lower &&
                $0.int64("sequence") <= upper }.compactMap { $0.string("key") })
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
                let key = group.string("key") ?? ""
                let source = group.string("sourceGroupID")
                let compensation = group.string("compensationGroupID")
                if kept.contains(key) {
                    if let source { kept.insert(source) }
                    if let compensation { kept.insert(compensation) }
                } else if source.map(kept.contains) == true || compensation.map(kept.contains) == true {
                    kept.insert(key)
                }
            }
            changed = kept.count != before
        }
        return kept.intersection(Set(groups.compactMap { $0.string("key") }))
    }

    func retireAcceptedGroup(_ group: NSManagedObject) throws {
        let groupID = try group.uuid("key")
        let transactionKey = self.transactionKey(groupID)
        guard let transaction = try fetchOne("HistoryTransactionRecord", key: transactionKey),
              transaction.string("stage") == "accepted" else {
            throw HistoryFailure(.storage, stage: .finalization, disposition: .suspended)
        }
        let retired = insert("HistoryRetiredCommandRecord")
        retired.setValue(transactionKey, forKey: "key")
        retired.setValue(scope.uuidString, forKey: "scopeKey")
        retired.setValue(transaction.string("generationID"), forKey: "generationID")
        retired.setValue(transaction.string("commandID"), forKey: "commandID")
        retired.setValue(transaction.data("fingerprint"), forKey: "fingerprint")
        retired.setValue(transaction.int64("sequence"), forKey: "sequence")
        retired.setValue(groupID.uuidString, forKey: "groupID")
        for action in try fetch("HistoryActionRecord", predicate: NSPredicate(
            format: "group == %@", group)) {
            try removeResourceReferences(ownerType: "action", ownerKey: action.string("key") ?? "")
        }
        let gap = insert("HistoryGapRecord")
        gap.setValue(UUID().uuidString, forKey: "key")
        gap.setValue(scope.uuidString, forKey: "scopeKey")
        gap.setValue(transaction.string("generationID"), forKey: "generationID")
        gap.setValue(group.int64("sequence") - 1, forKey: "lowerExclusiveSequence")
        gap.setValue(group.int64("sequence"), forKey: "upperInclusiveSequence")
        context.delete(group)
        context.delete(transaction)
    }
}
