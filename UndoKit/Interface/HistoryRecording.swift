// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Host-selected durability for new ordinary Actions in one History Scope.
/// Off keeps transaction preparation and recovery while ordinary Undo remains
/// available only during the open engine session.
public enum HistoryRecordingMode: Equatable, Sendable {
    /// Retain finalized ordinary Actions for reopening and historical reads.
    case on
    /// Keep safe preparation and reconciliation, with ordinary Undo only for this open session.
    case off
}

extension HistoryEngine {
    /// Read the persisted mode; storage failures are returned to the host.
    public func recordingMode() throws -> HistoryRecordingMode {
        try transaction.recordingMode()
    }

    /// Change recording only at a settled boundary. Existing retained history
    /// and checkpoints remain available. The first accepted Off edit creates an
    /// Undo gap. Re-enabling requires a coherent host baseline and returns its
    /// checkpoint ID; Off returns nil. A failed transition leaves the mode intact.
    @discardableResult public func setRecording(
        _ mode: HistoryRecordingMode, baseline: HistoryPayload? = nil,
        resources: [HistoryObjectReference] = []
    ) throws -> UUID? {
        try transaction.setRecording(mode, baseline: baseline, resources: resources, protection: retained)
    }
}
