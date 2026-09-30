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

public enum HistoryRecoveryDirection: Equatable, Sendable {
    case forward
    case reverse
}

/// An open-session handle. Release it when reconstruction finishes or is cancelled.
public struct HistoryRecoveryPlan: Equatable, Sendable {
    public let id: UUID
    public let scope: UUID
    public let generation: UUID
    public let committedVersion: Int64
    public let source: HistoryRecoverySource
    public let target: HistoryRecoveryTarget
    public let baselineSequence: Int64
    public let targetSequence: Int64
    public let direction: HistoryRecoveryDirection

    public init(id: UUID, scope: UUID, generation: UUID, committedVersion: Int64,
                source: HistoryRecoverySource, target: HistoryRecoveryTarget,
                baselineSequence: Int64, targetSequence: Int64,
                direction: HistoryRecoveryDirection) {
        self.id = id
        self.scope = scope
        self.generation = generation
        self.committedVersion = committedVersion
        self.source = source
        self.target = target
        self.baselineSequence = baselineSequence
        self.targetSequence = targetSequence
        self.direction = direction
    }
}

/// A lightweight reference to a complete accepted transition. Read each member's
/// opaque material separately, in reverse ordinal order for reverse plans.
public struct HistoryRecoveryStep: Equatable, Sendable {
    public let groupID: UUID
    public let sequence: Int64
    public let memberCount: Int
    public let kind: HistoryEntryKind
    public let restorationOrigin: UUID?
}

public struct HistoryRecoveryPage: Equatable, Sendable {
    public let steps: [HistoryRecoveryStep]
    /// Pass this cursor to the next read. Nil means the plan is exhausted.
    public let nextCursor: Int64?
}

public struct HistoryRecoveryMaterial: Equatable, Sendable {
    public let memberID: UUID
    public let ordinal: Int
    public let payload: HistoryPayload
}

/// One coherent committed read point within a scope generation.
public struct HistoryReadIdentity: Equatable, Sendable {
    public let scope: UUID
    public let generation: UUID
    public let committedVersion: Int64
    public let latestAcceptedSequence: Int64
    public let latestGroupID: UUID?
}

/// Host-resolved names to pass to the native router with the matching snapshot.
public struct HistoryNativeActionNames: Equatable, Sendable {
    public let undo: String
    public let redo: String
}

/// A retained, open-session sequence interval for pruning to respect.
public struct HistoryProtectedInterval: Equatable, Sendable {
    public let lowerExclusiveSequence: Int64
    public let upperInclusiveSequence: Int64
    public let checkpointID: UUID?
}
