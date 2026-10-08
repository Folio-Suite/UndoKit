// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import CoreData

extension HistoryTransactionCoordinator {
    /// Session-only inverse effects release their resource protection after a
    /// safe close or a settled reopening. Unresolved outcomes keep evidence.
    func releaseSessionReferences(save: Bool = true) throws {
        guard !snapshot.isSuspended else { return }
        let rows = try history.fetch(HistoryResourceRecord.self, predicate: NSPredicate(
            format: "\(#keyPath(HistoryResourceRecord.ownerType)) == %@ AND \(#keyPath(HistoryResourceRecord.ownerKey)) BEGINSWITH %@", "session", scope.uuidString + ":"))
        for row in rows {
            try history.removeResourceReferences(ownerType: "session", ownerKey: row.ownerKey ?? "")
        }
        if save && context.hasChanges { try history.saveContext() }
    }

    /// Read the persisted mode; storage failures are returned to the host.
    func recordingMode() throws -> HistoryRecordingMode {
        try history.scopeRecord().recordingEnabled ? .on : .off
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
        guard row.recordingEnabled != enabled else { return nil }
        let hadOffAction = row.offStartSequence > 0 &&
            row.undoFloorSequence >= row.offStartSequence
        var baselineID: UUID?
        if enabled {
            guard let baseline, history.valid(baseline), history.valid(resources),
                  history.hasCapacity(bytes: baseline.data.count) else {
                throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
            }
            let id = UUID()
            let sequence = row.nextSequence
            let checkpoint = history.insert(HistoryCheckpointRecord.self)
            checkpoint.key = id.uuidString
            checkpoint.scopeKey = scope.uuidString
            checkpoint.name = nil
            checkpoint.sequence = sequence
            checkpoint.latestAcceptedSequence = row.latestAcceptedSequence
            checkpoint.recordedAt = Date()
            checkpoint.family = baseline.family
            checkpoint.version = Int64(baseline.version)
            checkpoint.state = baseline.data
            checkpoint.stateDigest = history.digest(baseline)
            try history.addResourceReferences(resources, ownerType: "checkpoint", ownerKey: history.transactionKey(id))
            row.nextSequence = sequence + 1
            if hadOffAction { row.currentBaselineSequence = sequence }
            baselineID = id
        }
        row.recordingEnabled = enabled
        if enabled {
            try releaseSessionReferences(save: false)
            if hadOffAction { row.undoFloorSequence = row.nextSequence }
            row.offStartSequence = Int64(0)
        } else {
            row.offStartSequence = row.nextSequence
        }
        row.committedVersion += 1
        try history.saveRetention()
        if enabled { sessionGroups.removeAll() }
        updateSnapshot()
        return baselineID
    }
}
