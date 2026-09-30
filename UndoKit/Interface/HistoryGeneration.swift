// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryEngine {
    /// Explicitly omit this scope's retained history after the host has adopted
    /// coherent current state. All transactions must be settled. Other scopes,
    /// native Document Versions, backups, and host resources are untouched.
    @discardableResult public func clearHistory(
        adopting baseline: HistoryPayload, resources: [HistoryObjectReference] = []
    ) throws -> UUID {
        try requireIdleRetention()
        guard recoveryPlans.isEmpty else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        return try retireGeneration(adopting: baseline, resources: resources)
    }

    /// Acknowledge lost continuity from an irrecoverable unresolved outcome.
    /// The entire failed store is first copied to the caller's absent quarantine
    /// URL; reset proceeds only after that copy succeeds. The host must establish
    /// current domain reality independently before calling this method.
    @discardableResult public func resetUnresolvedHistory(
        adopting baseline: HistoryPayload, resources: [HistoryObjectReference] = [],
        quarantineAt destination: URL
    ) throws -> UUID {
        guard store.access == .readWrite, !store.writeFailed, !closed, !closing,
              !store.closed, !store.closing, !store.maintenance,
              !draining, queue.isEmpty, !reconciling, recoveryPlans.isEmpty,
              snapshot.isSuspended,
              !HistoryStore.deliveringStores.contains(ObjectIdentifier(store)) else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        let pending = try fetch("HistoryTransactionRecord", predicate: NSPredicate(
            format: "scopeKey == %@ AND stage != %@ AND stage != %@ AND stage != %@",
            scope.uuidString, "accepted", "rejected", "cancelled"))
        guard !pending.isEmpty else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        try store.copyIdle(to: destination, allowingUnresolved: true)
        return try retireGeneration(adopting: baseline, resources: resources)
    }

    private func retireGeneration(adopting baseline: HistoryPayload,
                                  resources: [HistoryObjectReference]) throws -> UUID {
        guard valid(baseline), valid(resources), hasCapacity(bytes: baseline.data.count) else {
            throw HistoryFailure(.capacity, stage: .admission, disposition: .usable)
        }
        let generation = UUID()
        do {
            for name in ["HistoryTransactionRecord", "HistoryGroupRecord",
                         "HistoryCheckpointRecord", "HistoryGapRecord", "HistoryHoldRecord",
                         "HistoryRetiredCommandRecord"] {
                for row in try fetch(name, predicate: NSPredicate(
                    format: "scopeKey == %@", scope.uuidString)) {
                    context.delete(row)
                }
            }
            let references = try fetch("HistoryResourceRecord", predicate: NSPredicate(
                format: "ownerKey BEGINSWITH %@", scope.uuidString + ":"))
            for row in references {
                try removeResourceReferences(ownerType: row.string("ownerType") ?? "",
                                             ownerKey: row.string("ownerKey") ?? "")
            }
            let row = try scopeRecord()
            row.setValue(generation.uuidString, forKey: "generationID")
            row.setValue(Int64(2), forKey: "nextSequence")
            row.setValue(Int64(0), forKey: "latestAcceptedSequence")
            row.setValue(Int64(2), forKey: "undoFloorSequence")
            row.setValue(Int64(1), forKey: "currentBaselineSequence")
            row.setValue(true, forKey: "requiresGenerationBinding")
            row.setValue(Int64(0), forKey: "offStartSequence")
            row.setValue(false, forKey: "suspended")
            row.setValue(row.int64("committedVersion") + 1, forKey: "committedVersion")
            let checkpointID = UUID()
            let checkpoint = insert("HistoryCheckpointRecord")
            checkpoint.setValue(checkpointID.uuidString, forKey: "key")
            checkpoint.setValue(scope.uuidString, forKey: "scopeKey")
            checkpoint.setValue(nil, forKey: "name")
            checkpoint.setValue(Int64(1), forKey: "sequence")
            checkpoint.setValue(Int64(0), forKey: "latestAcceptedSequence")
            checkpoint.setValue(Date(), forKey: "recordedAt")
            checkpoint.setValue(baseline.family, forKey: "family")
            checkpoint.setValue(Int64(baseline.version), forKey: "version")
            checkpoint.setValue(baseline.data, forKey: "state")
            checkpoint.setValue(digest(baseline), forKey: "stateDigest")
            try addResourceReferences(resources, ownerType: "checkpoint",
                                      ownerKey: transactionKey(checkpointID))
            try saveContext()
            sessionGroups.removeAll()
            invalidateRecoveryPlans()
            updateSnapshot()
            return generation
        } catch {
            context.rollback()
            throw error
        }
    }
}
