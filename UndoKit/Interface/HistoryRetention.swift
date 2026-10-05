// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// An opaque, version-specific object in a host-owned Retention Store.
/// Keys are canonical UTF-8 identifiers, not file paths or bytes to be decoded by UndoKit.
/// `nil` is the sole unversioned form. An explicit empty version key is rejected
/// when a host submits references because it shares the stored unversioned value.
public struct HistoryObjectReference: Hashable, Sendable {
    /// Stable identity of the host-owned Retention Store; no storage technology is implied.
    public let storeID: UUID
    /// Nonempty canonical UTF-8 object identity, bounded to 512 bytes on admission.
    public let objectKey: String
    /// Optional canonical version or digest identity, bounded to 256 bytes; empty is invalid.
    public let versionKey: String?

    /// Creates an opaque dependency reference without opening or copying the object.
    /// The host secures its bytes before acceptance; history admission validates key bounds.
    public init(storeID: UUID, objectKey: String, versionKey: String? = nil) {
        self.storeID = storeID
        self.objectKey = objectKey
        self.versionKey = versionKey
    }
}

/// A durable promise scoped to one History Generation. State holds protect a
/// checkpoint and its resources. Detail holds protect complete accepted groups
/// in an inclusive sequence interval, without extending ordinary Undo depth.
public struct HistoryRetentionHold: Equatable, Sendable {
    /// Independent state or detail protection; neither changes ordinary Undo depth.
    public enum Kind: Equatable, Sendable {
        /// Protect the checkpoint state and its declared dependencies, without preserving every earlier edit.
        case state(checkpointID: UUID)
        /// Protect complete accepted groups in the inclusive interval, without promising a state snapshot.
        case detail(firstSequence: Int64, lastSequence: Int64)
    }

    /// Stable identity used to release this promise independently of overlapping holds.
    public let id: UUID
    /// Host-defined history containing the protected material.
    public let scope: UUID
    /// Continuity boundary in which this hold remains valid.
    public let generation: UUID
    /// Protected state or detail interval; created through ``HistoryRetentionManaging``.
    public let kind: Kind
}

/// Application policy for one consolidation pass. No schedule is imposed.
/// `targetDetailedGroups` is a storage target, never an Undo depth override.
public struct HistoryRetentionPolicy: Sendable {
    /// Nonnegative desired retained group count. Protected material may prevent reaching it.
    public let targetDetailedGroups: Int
    /// Additional existing checkpoints to protect in this pass; this is not a durable hold.
    public let keptCheckpointIDs: Set<UUID>

    /// Selects a consolidation target and checkpoint exceptions, validated when consolidation runs.
    /// The boundary checkpoint, durable holds and active plans remain protected independently.
    public init(targetDetailedGroups: Int, keptCheckpointIDs: Set<UUID> = []) {
        self.targetDetailedGroups = targetDetailedGroups
        self.keptCheckpointIDs = keptCheckpointIDs
    }
}

/// One bounded, atomic consolidation step. Call again while `hasMore` is true.
/// Protected material may leave a requested target unmet.
public struct HistoryConsolidationResult: Equatable, Sendable {
    /// Accepted groups whose detail this atomic pass retired.
    public let removedGroups: Int
    /// Unprotected earlier checkpoint snapshots removed in this pass.
    public let removedCheckpoints: Int
    /// Distinct groups retained by depth, policy, current state, holds or Recovery Plans.
    public let protectedGroups: Int
    /// Total detailed accepted groups remaining in the scope after this pass.
    public let retainedGroups: Int
    /// Retained detail still exceeds the requested policy target, including protected groups.
    public let targetUnmet: Bool
    /// Further eligible groups or checkpoints remain for another bounded pass.
    public let hasMore: Bool
}

/// A distinct required object and the number of surviving records that require it.
public struct HistoryRequiredObject: Equatable, Sendable {
    /// One distinct object/version still required by surviving history or recovery records.
    public let reference: HistoryObjectReference
    /// Count of durable reference rows requiring this object; not a host-store ownership count.
    public let referenceCount: Int
}

/// A bounded page of distinct required objects across every scope in the store.
public struct HistoryRequiredObjectPage: Equatable, Sendable {
    /// Distinct requirements in canonical key/version order, at most the requested limit.
    public let objects: [HistoryRequiredObject]
    /// Pass to the next read; nil means no further objects existed at this read point.
    public let nextCursor: HistoryObjectReference?
}
