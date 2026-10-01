// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryEngine {
    func recoveryAcceptedSequence(_ source: HistoryRecoverySource) throws -> Int64 {
        switch source {
        case .current:
            return try history.scopeRecord().int64("latestAcceptedSequence")
        case .checkpoint(let id):
            let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryCheckpointRecord")
            request.predicate = NSPredicate(format: "scopeKey == %@ AND key == %@", scope.uuidString, id.uuidString)
            request.fetchLimit = 1
            guard let row = try context.fetch(request).first else {
                throw HistoryFailure(.missingHistory, stage: .admission, disposition: .usable)
            }
            return row.int64("latestAcceptedSequence")
        }
    }

    /// Validate the persisted transition chain rather than assuming every sequence
    /// is an accepted group: checkpoints and rejected requests legitimately consume numbers.
    func validateRecoveryChain(_ plan: HistoryRecoveryPlan, rows: [NSManagedObject],
                               after cursor: Int64?, exhausted: Bool) throws {
        let forward = plan.direction == .forward
        var expected = plan.baselineAcceptedSequence
        if let cursor {
            let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryGroupRecord")
            request.predicate = NSPredicate(format: "scopeKey == %@ AND sequence == %@",
                scope.uuidString, NSNumber(value: cursor))
            request.fetchLimit = 1
            guard let row = try context.fetch(request).first else { throw brokenRecoveryChain() }
            expected = forward ? cursor : row.int64("previousAcceptedSequence")
        }
        for row in rows {
            let sequence = row.int64("sequence")
            let previous = row.int64("previousAcceptedSequence")
            guard previous >= 0, previous < sequence,
                  (forward ? previous : sequence) == expected else { throw brokenRecoveryChain() }
            expected = forward ? sequence : previous
        }
        guard !exhausted || expected == plan.targetAcceptedSequence else { throw brokenRecoveryChain() }
    }

    private func brokenRecoveryChain() -> HistoryFailure {
        HistoryFailure(.corruptHistory, stage: .reconciliation, disposition: .usable,
                       underlyingDescription: "A required accepted transition is missing or inconsistent")
    }
}
