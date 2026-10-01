// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import CoreData

extension HistoryTransactionCoordinator {
    /// Session-only inverse effects release their resource protection after a
    /// safe close or a settled reopening. Unresolved outcomes keep evidence.
    func releaseSessionReferences(save: Bool = true) throws {
        guard !snapshot.isSuspended else { return }
        let rows = try history.fetch("HistoryResourceRecord", predicate: NSPredicate(
            format: "ownerType == %@ AND ownerKey BEGINSWITH %@", "session", scope.uuidString + ":"))
        for row in rows {
            try history.removeResourceReferences(ownerType: "session", ownerKey: row.string("ownerKey") ?? "")
        }
        if save && context.hasChanges { try history.saveContext() }
    }

    /// Read the persisted mode; storage failures are returned to the host.
    func recordingMode() throws -> HistoryRecordingMode {
        try history.scopeRecord().bool("recordingEnabled") ? .on : .off
    }

    /// Change recording only at a settled boundary. Existing retained history
    /// and checkpoints remain available. The first accepted Off edit creates an
    /// Undo gap. Re-enabling requires a coherent host baseline and returns its
    /// checkpoint ID; Off returns nil. A failed transition leaves the mode intact.
    @discardableResult func setRecording(
        _ mode: HistoryRecordingMode, baseline: HistoryPayload? = nil,
        resources: [HistoryObjectReference] = [], protection: any HistoryRecoveryProtection
    ) throws -> UUID? {
        try requireIdle()
        guard !protection.hasRecoveryPlans else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        let row = try history.scopeRecord()
        let enabled = mode == .on
        guard row.bool("recordingEnabled") != enabled else { return nil }
        let hadOffAction = row.int64("offStartSequence") > 0 &&
            row.int64("undoFloorSequence") >= row.int64("offStartSequence")
        var baselineID: UUID?
        if enabled {
            guard let baseline, history.valid(baseline), history.valid(resources),
                  history.hasCapacity(bytes: baseline.data.count) else {
                throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
            }
            let id = UUID()
            let sequence = row.int64("nextSequence")
            let checkpoint = history.insert("HistoryCheckpointRecord")
            checkpoint.setValue(id.uuidString, forKey: "key")
            checkpoint.setValue(scope.uuidString, forKey: "scopeKey")
            checkpoint.setValue(nil, forKey: "name")
            checkpoint.setValue(sequence, forKey: "sequence")
            checkpoint.setValue(row.int64("latestAcceptedSequence"), forKey: "latestAcceptedSequence")
            checkpoint.setValue(Date(), forKey: "recordedAt")
            checkpoint.setValue(baseline.family, forKey: "family")
            checkpoint.setValue(Int64(baseline.version), forKey: "version")
            checkpoint.setValue(baseline.data, forKey: "state")
            checkpoint.setValue(history.digest(baseline), forKey: "stateDigest")
            try history.addResourceReferences(resources, ownerType: "checkpoint", ownerKey: history.transactionKey(id))
            row.setValue(sequence + 1, forKey: "nextSequence")
            if hadOffAction { row.setValue(sequence, forKey: "currentBaselineSequence") }
            baselineID = id
        }
        row.setValue(enabled, forKey: "recordingEnabled")
        if enabled {
            try releaseSessionReferences(save: false)
            if hadOffAction { row.setValue(row.int64("nextSequence"), forKey: "undoFloorSequence") }
            row.setValue(Int64(0), forKey: "offStartSequence")
        } else {
            row.setValue(row.int64("nextSequence"), forKey: "offStartSequence")
        }
        row.setValue(row.int64("committedVersion") + 1, forKey: "committedVersion")
        try history.saveRetention()
        if enabled { sessionGroups.removeAll() }
        updateSnapshot()
        return baselineID
    }
}
