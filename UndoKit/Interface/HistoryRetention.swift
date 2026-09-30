// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// An opaque, version-specific object in a host-owned Retention Store.
/// Keys are canonical UTF-8 identifiers, not file paths or bytes to be decoded by UndoKit.
public struct HistoryObjectReference: Hashable, Sendable {
    public let storeID: UUID
    public let objectKey: String
    public let versionKey: String?

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
    public enum Kind: Equatable, Sendable {
        case state(checkpointID: UUID)
        case detail(firstSequence: Int64, lastSequence: Int64)
    }

    public let id: UUID
    public let scope: UUID
    public let generation: UUID
    public let kind: Kind
}

/// Application policy for one consolidation pass. No schedule is imposed.
/// `targetDetailedGroups` is a storage target, never an Undo depth override.
public struct HistoryRetentionPolicy: Sendable {
    public let targetDetailedGroups: Int
    public let keptCheckpointIDs: Set<UUID>

    public init(targetDetailedGroups: Int, keptCheckpointIDs: Set<UUID> = []) {
        self.targetDetailedGroups = targetDetailedGroups
        self.keptCheckpointIDs = keptCheckpointIDs
    }
}

/// One bounded, atomic consolidation step. Call again while `hasMore` is true.
/// Protected material may leave a requested target unmet.
public struct HistoryConsolidationResult: Equatable, Sendable {
    public let removedGroups: Int
    public let removedCheckpoints: Int
    public let protectedGroups: Int
    public let retainedGroups: Int
    public let targetUnmet: Bool
    public let hasMore: Bool
}

/// A distinct required object and the number of surviving records that require it.
public struct HistoryRequiredObject: Equatable, Sendable {
    public let reference: HistoryObjectReference
    public let referenceCount: Int
}

/// A bounded page of distinct required objects across every scope in the store.
public struct HistoryRequiredObjectPage: Equatable, Sendable {
    public let objects: [HistoryRequiredObject]
    public let nextCursor: HistoryObjectReference?
}
