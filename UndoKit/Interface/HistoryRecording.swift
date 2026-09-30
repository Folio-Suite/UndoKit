// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import CoreData

/// Host-selected durability for new ordinary Actions in one History Scope.
/// Off keeps transaction preparation and recovery while ordinary Undo remains
/// available only during the open engine session.
public enum HistoryRecordingMode: Equatable, Sendable { case on, off }

extension HistoryEngine {
    /// Session-only inverse effects release their resource protection after a
    /// safe close or a settled reopening. Unresolved outcomes keep evidence.
    func releaseSessionReferences(save: Bool = true) throws {
        guard !snapshot.isSuspended else { return }
        let rows = try fetch("HistoryResourceRecord", predicate: NSPredicate(
            format: "ownerType == %@ AND ownerKey BEGINSWITH %@", "session", scope.uuidString + ":"))
        for row in rows {
            try removeResourceReferences(ownerType: "session", ownerKey: row.string("ownerKey") ?? "")
        }
        if save && context.hasChanges { try saveContext() }
    }

    public var recordingMode: HistoryRecordingMode {
        (try? scopeRecord().bool("recordingEnabled")) == false ? .off : .on
    }

    /// Change recording only at a settled boundary. Existing retained history
    /// and checkpoints remain available; ordinary Undo cannot cross an Off gap.
    @discardableResult public func setRecording(
        _ mode: HistoryRecordingMode, baseline: HistoryPayload? = nil,
        resources: [HistoryObjectReference] = []
    ) throws -> UUID? {
        try requireIdleRetention()
        guard recoveryPlans.isEmpty else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        let row = try scopeRecord()
        let enabled = mode == .on
        guard row.bool("recordingEnabled") != enabled else { return nil }
        let hadOffAction = row.int64("offStartSequence") > 0 &&
            row.int64("undoFloorSequence") >= row.int64("offStartSequence")
        var baselineID: UUID?
        if enabled {
            guard let baseline, valid(baseline), valid(resources),
                  hasCapacity(bytes: baseline.data.count) else {
                throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
            }
            let id = UUID()
            let sequence = row.int64("nextSequence")
            let checkpoint = insert("HistoryCheckpointRecord")
            checkpoint.setValue(id.uuidString, forKey: "key")
            checkpoint.setValue(scope.uuidString, forKey: "scopeKey")
            checkpoint.setValue(nil, forKey: "name")
            checkpoint.setValue(sequence, forKey: "sequence")
            checkpoint.setValue(row.int64("latestAcceptedSequence"), forKey: "latestAcceptedSequence")
            checkpoint.setValue(Date(), forKey: "recordedAt")
            checkpoint.setValue(baseline.family, forKey: "family")
            checkpoint.setValue(Int64(baseline.version), forKey: "version")
            checkpoint.setValue(baseline.data, forKey: "state")
            checkpoint.setValue(digest(baseline), forKey: "stateDigest")
            try addResourceReferences(resources, ownerType: "checkpoint", ownerKey: transactionKey(id))
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
        try saveRetention()
        if enabled { sessionGroups.removeAll() }
        updateSnapshot()
        return baselineID
    }
}
