// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryTransactionCoordinator {
    /// Explicitly omit this scope's retained history after the host has adopted
    /// coherent current state. All transactions must be settled. Other scopes,
    /// native Document Versions, backups, and host resources are untouched.
    /// - Parameters:
    ///   - baseline: Host-authored current state for the new generation.
    ///   - resources: Opaque objects required by that state.
    /// - Returns: New generation ID. Subsequent submissions, Undo and Redo must
    ///   bind to this generation before host delivery.
    /// - Throws: Admission, storage or capacity failure. No generation is
    ///   retired when admission fails.
    @discardableResult func clearHistory(
        adopting baseline: HistoryPayload, resources: [HistoryObjectReference] = [],
        protection: any HistoryRecoveryProtection
    ) throws -> UUID {
        try requireIdle()
        guard !protection.hasRecoveryPlans else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        return try retireGeneration(adopting: baseline, resources: resources, protection: protection)
    }

    /// Acknowledge lost continuity from an irrecoverable unresolved outcome.
    /// The entire failed store is first copied to the caller's absent quarantine
    /// URL; reset proceeds only after that copy succeeds. The host must establish
    /// current domain reality independently before calling this method.
    /// - Parameters:
    ///   - baseline: Host-confirmed coherent current state.
    ///   - resources: Opaque objects required by that state.
    ///   - destination: Absent URL for the failed store copy.
    /// - Returns: New generation ID requiring client reattachment.
    /// - Throws: Busy without unresolved evidence, failed quarantine copy,
    ///   invalid input, capacity or storage failure.
    @discardableResult func resetUnresolvedHistory(
        adopting baseline: HistoryPayload, resources: [HistoryObjectReference] = [],
        quarantineAt destination: URL, protection: any HistoryRecoveryProtection
    ) throws -> UUID {
        guard store.access == .readWrite, !store.writeFailed, !closed, !closing,
              !store.closed, !store.closing, !store.maintenance,
              !isActive, !protection.hasRecoveryPlans,
              snapshot.isSuspended,
              !HistoryStore.deliveringStores.contains(ObjectIdentifier(store)) else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        let pending = try history.fetch("HistoryTransactionRecord", predicate: NSPredicate(
            format: "scopeKey == %@ AND stage != %@ AND stage != %@ AND stage != %@",
            scope.uuidString, "accepted", "rejected", "cancelled"))
        guard !pending.isEmpty else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        try store.copyIdle(to: destination, allowingUnresolved: true)
        return try retireGeneration(adopting: baseline, resources: resources, protection: protection)
    }

    private func retireGeneration(adopting baseline: HistoryPayload,
                                  resources: [HistoryObjectReference],
                                  protection: any HistoryRecoveryProtection) throws -> UUID {
        guard history.valid(baseline), history.valid(resources), history.hasCapacity(bytes: baseline.data.count) else {
            throw HistoryFailure(.capacity, stage: .admission, disposition: .usable)
        }
        let generation = UUID()
        do {
            for name in ["HistoryTransactionRecord", "HistoryGroupRecord",
                         "HistoryCheckpointRecord", "HistoryGapRecord", "HistoryHoldRecord",
                         "HistoryRetiredCommandRecord",
                        ] {
                for row in try history.fetch(name, predicate: NSPredicate(
                    format: "scopeKey == %@", scope.uuidString)) {
                    context.delete(row)
                }
            }
            let references = try history.fetch("HistoryResourceRecord", predicate: NSPredicate(
                format: "ownerKey BEGINSWITH %@", scope.uuidString + ":"))
            for row in references {
                try history.removeResourceReferences(ownerType: row.string("ownerType") ?? "",
                                             ownerKey: row.string("ownerKey") ?? "")
            }
            let row = try history.scopeRecord()
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
            let checkpoint = history.insert("HistoryCheckpointRecord")
            checkpoint.setValue(checkpointID.uuidString, forKey: "key")
            checkpoint.setValue(scope.uuidString, forKey: "scopeKey")
            checkpoint.setValue(nil, forKey: "name")
            checkpoint.setValue(Int64(1), forKey: "sequence")
            checkpoint.setValue(Int64(0), forKey: "latestAcceptedSequence")
            checkpoint.setValue(Date(), forKey: "recordedAt")
            checkpoint.setValue(baseline.family, forKey: "family")
            checkpoint.setValue(Int64(baseline.version), forKey: "version")
            checkpoint.setValue(baseline.data, forKey: "state")
            checkpoint.setValue(history.digest(baseline), forKey: "stateDigest")
            try history.addResourceReferences(resources, ownerType: "checkpoint",
                                      ownerKey: history.transactionKey(checkpointID))
            try history.saveContext()
            sessionGroups.removeAll()
            protection.invalidateRecoveryPlans()
            updateSnapshot()
            return generation
        } catch {
            context.rollback()
            throw error
        }
    }
}
