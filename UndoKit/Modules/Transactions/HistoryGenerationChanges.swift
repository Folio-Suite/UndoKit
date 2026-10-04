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
        let pending = try history.fetch(HistoryTransactionRecord.self, predicate: NSPredicate(
            format: "\(#keyPath(HistoryTransactionRecord.scopeKey)) == %@ AND " +
                "\(#keyPath(HistoryTransactionRecord.stage)) != %@ AND " +
                "\(#keyPath(HistoryTransactionRecord.stage)) != %@ AND " +
                "\(#keyPath(HistoryTransactionRecord.stage)) != %@",
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
            let scopedTypes: [(NSManagedObject.Type, String)] = [
                (HistoryTransactionRecord.self, #keyPath(HistoryTransactionRecord.scopeKey)),
                (HistoryGroupRecord.self, #keyPath(HistoryGroupRecord.scopeKey)),
                (HistoryCheckpointRecord.self, #keyPath(HistoryCheckpointRecord.scopeKey)),
                (HistoryGapRecord.self, #keyPath(HistoryGapRecord.scopeKey)),
                (HistoryHoldRecord.self, #keyPath(HistoryHoldRecord.scopeKey)),
                (HistoryRetiredCommandRecord.self, #keyPath(HistoryRetiredCommandRecord.scopeKey)),
            ]
            for (type, scopeKeyPath) in scopedTypes {
                for row in try history.fetch(type, predicate: NSPredicate(
                    format: "%K == %@", scopeKeyPath, scope.uuidString)) {
                    context.delete(row)
                }
            }
            let references = try history.fetch(HistoryResourceRecord.self, predicate: NSPredicate(
                format: "\(#keyPath(HistoryResourceRecord.ownerKey)) BEGINSWITH %@", scope.uuidString + ":"))
            for row in references {
                try history.removeResourceReferences(ownerType: row.ownerType ?? "",
                                             ownerKey: row.ownerKey ?? "")
            }
            let row = try history.scopeRecord()
            row.generationID = generation.uuidString
            row.nextSequence = Int64(2)
            row.latestAcceptedSequence = Int64(0)
            row.undoFloorSequence = Int64(2)
            row.currentBaselineSequence = Int64(1)
            row.requiresGenerationBinding = true
            row.offStartSequence = Int64(0)
            row.suspended = false
            row.committedVersion += 1
            let checkpointID = UUID()
            let checkpoint = history.insert(HistoryCheckpointRecord.self)
            checkpoint.key = checkpointID.uuidString
            checkpoint.scopeKey = scope.uuidString
            checkpoint.name = nil
            checkpoint.sequence = Int64(1)
            checkpoint.latestAcceptedSequence = Int64(0)
            checkpoint.recordedAt = Date()
            checkpoint.family = baseline.family
            checkpoint.version = Int64(baseline.version)
            checkpoint.state = baseline.data
            checkpoint.stateDigest = history.digest(baseline)
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
