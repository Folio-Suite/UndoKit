// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

enum HistoryHostCallbackContext {
    @TaskLocal static var activeEngines: Set<ObjectIdentifier> = []
}

/// An opaque, versioned value supplied and interpreted by a history host.
public struct HistoryPayload: Equatable, Sendable {
    public let family: String
    public let version: Int
    public let data: Data

    public init(family: String, version: Int = 1, data: Data) {
        self.family = family
        self.version = version
        self.data = data
    }
}

/// One independently identified member of an atomic host operation.
/// Members execute in listed order and reverse in the opposite order.
public struct HistoryMember: Equatable, Sendable {
    public let id: UUID
    public let payload: HistoryPayload

    public init(id: UUID = UUID(), payload: HistoryPayload) {
        self.id = id
        self.payload = payload
    }
}

/// An identified semantic request. The host owns no-op filtering and validation.
/// A retry must keep its ID, members and canonical intent fingerprint unchanged.
public struct HistoryCommand: Equatable, Sendable {
    public let id: UUID
    public let fingerprint: Data
    public let members: [HistoryMember]
    public let restorationOrigin: UUID?
    /// Small host-authored display data. It is never required to recover an effect.
    public let presentation: HistoryPayload?
    /// Required after an explicit generation reset; binds delayed submissions
    /// to the generation in which the host created them.
    public let expectedGeneration: UUID?

    public init(id: UUID = UUID(), fingerprint: Data, members: [HistoryMember],
                restorationOrigin: UUID? = nil, presentation: HistoryPayload? = nil,
                expectedGeneration: UUID? = nil) {
        self.id = id
        self.fingerprint = fingerprint
        self.members = members
        self.restorationOrigin = restorationOrigin
        self.presentation = presentation
        self.expectedGeneration = expectedGeneration
    }

    public init(id: UUID = UUID(), fingerprint: Data, payload: HistoryPayload,
                restorationOrigin: UUID? = nil, presentation: HistoryPayload? = nil,
                expectedGeneration: UUID? = nil) {
        self.init(id: id, fingerprint: fingerprint,
                  members: [HistoryMember(id: id, payload: payload)],
                  restorationOrigin: restorationOrigin, presentation: presentation,
                  expectedGeneration: expectedGeneration)
    }
}

/// A durable identity for one prepared history transaction.
/// Hosts include it in authoritative domain receipts and use it for outcome lookup.
public struct HistoryToken: Equatable, Hashable, Sendable {
    public let scope: UUID
    public let generation: UUID
    public let sequence: Int64
    public let command: UUID

    public init(scope: UUID, generation: UUID, sequence: Int64, command: UUID) {
        self.scope = scope
        self.generation = generation
        self.sequence = sequence
        self.command = command
    }
}

/// The semantic role of one whole-group host delivery.
public enum HistoryDeliveryKind: String, Sendable { case command, undo, redo }

/// The host executes every member in this delivery atomically and records its token with the domain effect.
public struct HistoryDelivery: Sendable {
    public let token: HistoryToken
    public let kind: HistoryDeliveryKind
    public let members: [HistoryMember]
    public let restorationOrigin: UUID?

    public init(token: HistoryToken, kind: HistoryDeliveryKind, members: [HistoryMember], restorationOrigin: UUID?) {
        self.token = token
        self.kind = kind
        self.members = members
        self.restorationOrigin = restorationOrigin
    }
}

/// Host evidence for one accepted member, including future inverse and reapplication inputs.
/// The host must be able to reconstruct this value from its durable receipt after interruption.
public struct HistoryEffect: Equatable, Sendable {
    public let memberID: UUID
    public let undo: HistoryPayload
    public let redo: HistoryPayload
    /// Opaque dependencies of this accepted effect, including versions required by recovery.
    public let resources: [HistoryObjectReference]

    public init(memberID: UUID, undo: HistoryPayload, redo: HistoryPayload,
                resources: [HistoryObjectReference] = []) {
        self.memberID = memberID
        self.undo = undo
        self.redo = redo
        self.resources = resources
    }
}

/// An authoritative domain outcome. A thrown callback or absent receipt is unresolved.
/// Rejection proves no semantic effect; acceptance covers every member atomically.
public enum HistoryHostOutcome: Equatable, Sendable {
    case accepted([HistoryEffect])
    case rejected
    case unresolved
    /// A callback may report a known pre-effect failure. Failures after a possible
    /// semantic effect must remain `unresolved` until authoritative lookup.
    case failure(HistoryFailure)
}

/// A host adapter must persist an accepted receipt with its semantic mutation.
/// Implementations may be isolated to any actor. Only opaque, Sendable history
/// values cross this boundary; domain values remain on the host's actor.
/// Outcome lookup never applies a command again.
public protocol HistoryHost: AnyObject, Sendable {
    /// Applies all members atomically or proves that none took effect.
    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome
    /// Reads authoritative durable evidence for an already prepared token.
    func outcome(for token: HistoryToken) async -> HistoryHostOutcome
}

/// Broad failure categories independent of a host's domain vocabulary.
public enum HistoryFailureCause: String, Sendable {
    case storage, capacity, identityConflict, invalidInput, hostProtocol, unresolved, busy, compatibility, cancelled
    /// A host expected registered history, but no database exists at that location.
    case missingHistory
    /// Existing bytes are not a readable SQLite history database.
    case corruptHistory
    /// The expected location exists but cannot currently be opened.
    case unavailableStore
}

/// The transaction stage at which completion failed.
public enum HistoryFailureStage: String, Sendable {
    case admission, preparation, delivery, reconciliation, finalization
}
/// Whether this scope can continue accepting semantic mutations.
public enum HistoryScopeDisposition: String, Sendable { case usable, suspended, resetRequired }

/// A typed failure. Underlying text is diagnostic and never changes the disposition.
public struct HistoryFailure: Error, Equatable, Sendable {
    public let cause: HistoryFailureCause
    public let stage: HistoryFailureStage
    public let disposition: HistoryScopeDisposition
    public let underlyingDescription: String?

    public init(_ cause: HistoryFailureCause, stage: HistoryFailureStage,
                disposition: HistoryScopeDisposition, underlyingDescription: String? = nil) {
        self.cause = cause
        self.stage = stage
        self.disposition = disposition
        self.underlyingDescription = underlyingDescription
    }
}

/// A receipt returned only after the domain effect and history relation finalize.
public struct HistoryReceipt: Equatable, Sendable {
    public let token: HistoryToken
    public let groupID: UUID

    public init(token: HistoryToken, groupID: UUID) {
        self.token = token
        self.groupID = groupID
    }
}

/// Completion for one queued request. Rejected means authoritative no-effect.
public enum HistoryResult: Equatable, Sendable {
    case accepted(HistoryReceipt)
    case rejected
    case failure(HistoryFailure)
}

/// Coherent ordinary availability after the latest completed engine transition.
/// Version increments when these values change within an open engine session.
public struct HistorySnapshot: Equatable, Sendable {
    public let scope: UUID?
    public let generation: UUID?
    public let version: Int64
    public let canUndo: Bool
    public let canRedo: Bool
    public let isSuspended: Bool
    public let hasPending: Bool

    public init(canUndo: Bool, canRedo: Bool, isSuspended: Bool, hasPending: Bool,
                scope: UUID? = nil, generation: UUID? = nil, version: Int64 = 0) {
        self.scope = scope
        self.generation = generation
        self.version = version
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.isSuspended = isSuspended
        self.hasPending = hasPending
    }
}

/// Provisional operation limits. Hosts may choose stricter values up to compiled ceilings.
/// Capacity admission reserves room for worst-case bounded inverse and Redo evidence.
public struct HistoryLimits: Equatable, Sendable {
    public var maxPayloadBytes: Int
    public var maxMembers: Int
    public var maxQueueDepth: Int
    public var maxStoreBytes: Int64
    public var maxUndoGroups: Int
    public var maxReadPage: Int
    public var maxRecoveryPlans: Int

    public init(maxPayloadBytes: Int = 8 * 1024 * 1024, maxMembers: Int = 100,
                maxQueueDepth: Int = 64, maxStoreBytes: Int64 = 2 * 1024 * 1024 * 1024,
                maxUndoGroups: Int = 1_000, maxReadPage: Int = 100,
                maxRecoveryPlans: Int = 32) {
        self.maxPayloadBytes = maxPayloadBytes
        self.maxMembers = maxMembers
        self.maxQueueDepth = maxQueueDepth
        self.maxStoreBytes = maxStoreBytes
        self.maxUndoGroups = maxUndoGroups
        self.maxReadPage = maxReadPage
        self.maxRecoveryPlans = maxRecoveryPlans
    }
}

/// The role of a retained accepted group in structural history.
public enum HistoryEntryKind: String, Sendable { case command, undo, redo }

/// Structural history metadata. Reading an entry never decodes its host payload.
public struct HistoryEntry: Equatable, Sendable {
    public let groupID: UUID
    public let sequence: Int64
    public let kind: HistoryEntryKind
    public let sourceGroupID: UUID?
    public let compensationGroupID: UUID?
    public let restorationOrigin: UUID?
    public let memberCount: Int
    public let recordedAt: Date

    public init(groupID: UUID, sequence: Int64, kind: HistoryEntryKind,
                sourceGroupID: UUID? = nil, compensationGroupID: UUID? = nil,
                restorationOrigin: UUID?, memberCount: Int, recordedAt: Date) {
        self.groupID = groupID
        self.sequence = sequence
        self.kind = kind
        self.sourceGroupID = sourceGroupID
        self.compensationGroupID = compensationGroupID
        self.restorationOrigin = restorationOrigin
        self.memberCount = memberCount
        self.recordedAt = recordedAt
    }
}

/// Bounded checkpoint metadata; its state is fetched separately.
public struct HistoryCheckpointInfo: Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let sequence: Int64
    public let recordedAt: Date

    public init(id: UUID, name: String?, sequence: Int64, recordedAt: Date) {
        self.id = id
        self.name = name
        self.sequence = sequence
        self.recordedAt = recordedAt
    }
}

/// A host-authored coherent historical state and its durable metadata.
public struct HistoryCheckpoint: Equatable, Sendable {
    public let info: HistoryCheckpointInfo
    public let state: HistoryPayload

    public init(info: HistoryCheckpointInfo, state: HistoryPayload) {
        self.info = info
        self.state = state
    }
}
