// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// The host promises that each accepted effect's undo and redo payloads can be
/// interpreted as historical state transitions, without executing the command.
public enum HistoryReconstructionEvidence: Sendable {
    case acceptedEffects
}

/// A coherent source state already held by the host, or a stored state snapshot.
public enum HistoryRecoverySource: Equatable, Sendable {
    case current
    case checkpoint(UUID)
}

/// The state immediately after an accepted group, or the state of a checkpoint.
public enum HistoryRecoveryTarget: Equatable, Sendable {
    case group(UUID)
    case checkpoint(UUID)
}

/// Forward applies members in ascending ordinal order; reverse applies descending order.
public enum HistoryRecoveryDirection: Equatable, Sendable {
    case forward
    case reverse
}

/// An open-session handle. Release it when reconstruction finishes or is cancelled.
public struct HistoryRecoveryPlan: Equatable, Sendable {
    /// Engine-issued identity valid only for this open scope session.
    public let id: UUID
    /// Host-defined scope containing this view.
    public let scope: UUID
    /// History continuity boundary captured when this view was issued.
    public let generation: UUID
    /// Durable history version captured by this view; later writes do not extend a plan.
    public let committedVersion: Int64
    /// Host-held current state or stored checkpoint used as the reconstruction baseline.
    public let source: HistoryRecoverySource
    /// Selected historical endpoint, without changing the live Undo position.
    public let target: HistoryRecoveryTarget
    /// Sequence of the state from which reconstruction starts.
    public let baselineSequence: Int64
    /// Sequence of the selected state after reconstruction.
    public let targetSequence: Int64
    /// Determines traversal and member application order.
    public let direction: HistoryRecoveryDirection

    let baselineAcceptedSequence: Int64
    let targetAcceptedSequence: Int64


}

/// A lightweight reference to a complete accepted transition. Read each member's
/// opaque material separately, in reverse ordinal order for reverse plans.
public struct HistoryRecoveryStep: Equatable, Sendable {
    /// Accepted group whose members can be retrieved individually.
    public let groupID: UUID
    /// Accepted transition position in the scope chronology.
    public let sequence: Int64
    /// Number of complete-group members; valid ordinals are zero through count minus one.
    public let memberCount: Int
    /// Structural command, Undo or Redo classification.
    public let kind: HistoryEntryKind
    /// Host-supplied provenance of a restoration command, when present.
    public let restorationOrigin: UUID?
}

/// One bounded page of lightweight transition references.
public struct HistoryRecoveryPage: Equatable, Sendable {
    /// At most the requested limit, ordered in the plan traversal direction.
    public let steps: [HistoryRecoveryStep]
    /// Pass this cursor to the next read. Nil means the plan is exhausted.
    public let nextCursor: Int64?
}

/// One member of host-owned reconstruction evidence.
public struct HistoryRecoveryMaterial: Equatable, Sendable {
    /// Stable identity of this accepted group member.
    public let memberID: UUID
    /// Zero-based member position within the group.
    public let ordinal: Int
    /// Integrity-checked opaque Undo or Redo evidence selected by plan direction.
    public let payload: HistoryPayload
}

/// One coherent committed read point within a scope generation.
public struct HistoryReadIdentity: Equatable, Sendable {
    /// Host-defined scope containing this view.
    public let scope: UUID
    /// History continuity boundary captured when this view was issued.
    public let generation: UUID
    /// Durable history version captured by this view; later writes do not extend a plan.
    public let committedVersion: Int64
    /// Latest accepted transition, or zero for an empty scope.
    public let latestAcceptedSequence: Int64
    /// Latest accepted group, absent for an empty scope.
    public let latestGroupID: UUID?
}

/// Host-resolved names to pass to the native router with the matching snapshot.
public struct HistoryNativeActionNames: Equatable, Sendable {
    /// Host-resolved Undo label; empty requests the native generic label.
    public let undo: String
    /// Host-resolved Redo label; empty requests the native generic label.
    public let redo: String
}
