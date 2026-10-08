// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// An opaque, versioned value supplied and interpreted by a history host.
/// Admission requires a nonempty family of at most 256 UTF-8 bytes, a positive
/// schema version and bytes within ``HistoryLimits/maxPayloadBytes``. Construction
/// alone does not validate these requirements or establish stored-byte integrity.
public struct HistoryPayload: Equatable, Sendable {
    /// Stable host-defined operation or payload family; independent of Swift type names.
    public let family: String
    /// Positive host schema version used to select the registered decoder.
    public let version: Int
    /// Opaque encoded bytes. Admission bounds their size; UndoKit does not interpret them.
    public let data: Data

    /// Creates an encoding description without decoding or validating its bytes.
    /// Family, version and capacity are checked when the value enters history.
    public init(family: String, version: Int = 1, data: Data) {
        self.family = family
        self.version = version
        self.data = data
    }
}

/// One independently identified member of an atomic host operation.
/// Members execute in listed order and reverse in the opposite order.
public struct HistoryMember: Equatable, Sendable {
    /// Stable member identity preserved in accepted effects and future inverses.
    public let id: UUID
    /// Command or inverse input interpreted only by the host.
    public let payload: HistoryPayload

    /// Creates one member. Supply the same identity when retrying the same Command.
    public init(id: UUID = UUID(), payload: HistoryPayload) {
        self.id = id
        self.payload = payload
    }
}

/// An identified semantic request. The host owns no-op filtering and validation.
/// A retry must keep its ID, members and canonical intent fingerprint unchanged.
public struct HistoryCommand: Equatable, Sendable {
    /// Stable Command identity. A later user attempt with new intent needs a new identity.
    public let id: UUID
    /// Nonempty host fingerprint of canonical intent, at most 4 KiB.
    /// It is distinct from stored-byte integrity checks.
    public let fingerprint: Data
    /// Nonempty ordered atomic group. Member identities must be unique within the group.
    public let members: [HistoryMember]
    /// Host-authored historical provenance; restoration still executes as a new Command.
    public let restorationOrigin: UUID?
    /// Host-authored display data with at most 4 KiB of encoded bytes.
    /// It is never required to recover an effect.
    public let presentation: HistoryPayload?
    /// Required after an explicit generation reset; binds delayed submissions
    /// to the generation in which the host created them.
    public let expectedGeneration: UUID?

    /// Creates a whole-group request without delivering it.
    /// The host must implement all-or-nothing semantics and secure accepted-effect dependencies.
    /// Construction does not establish admission or acceptance; submit through ``HistoryTransactions``.
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

    /// Creates a single-member request using the Command identity as its member identity.
    /// Keep the identity, fingerprint and payload unchanged for an exact retry.
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
    /// Host-defined independent history receiving this transaction.
    public let scope: UUID
    /// Continuity boundary in which the transaction was durably prepared.
    public let generation: UUID
    /// Store-assigned order within the scope; rejected requests may leave sequence holes.
    public let sequence: Int64
    /// Stable identity of the prepared Command or generated whole-group inverse.
    public let command: UUID

    /// Describes an existing prepared identity, for example when rebuilding durable host evidence.
    /// Constructing a token does not prepare, authorize or finalize a transaction.
    public init(scope: UUID, generation: UUID, sequence: Int64, command: UUID) {
        self.scope = scope
        self.generation = generation
        self.sequence = sequence
        self.command = command
    }
}

/// The semantic role of one whole-group host delivery.
public enum HistoryDeliveryKind: String, Sendable {
    /// Execute the host’s submitted semantic intent.
    case command
    /// Compensate a complete eligible group using accepted Undo evidence.
    case undo
    /// Reapply a complete eligible group using accepted Redo evidence.
    case redo
}

/// The host executes every member in this delivery atomically and records its token with the domain effect.
public struct HistoryDelivery: Sendable {
    /// Persist this identity with the atomic domain effect so interruption can be reconciled.
    public let token: HistoryToken
    /// Selects ordinary execution, compensation or reapplication in the host.
    public let kind: HistoryDeliveryKind
    /// Complete host operation in delivery order; Undo members are already reversed.
    public let members: [HistoryMember]
    /// Host-authored historical provenance, if this delivery restores an earlier state.
    public let restorationOrigin: UUID?

    /// Packages one complete delivery. Hosts ordinarily receive this value from the engine;
    /// constructing it does not commit a preparation record or establish an accepted outcome.
    public init(token: HistoryToken, kind: HistoryDeliveryKind, members: [HistoryMember], restorationOrigin: UUID?) {
        self.token = token
        self.kind = kind
        self.members = members
        self.restorationOrigin = restorationOrigin
    }
}

/// Host evidence for one accepted member, including future inverse and reapplication inputs.
/// The host must be able to reconstruct this value from its durable receipt after interruption.
/// Each inverse payload obeys ``HistoryLimits/maxPayloadBytes``; the group's
/// combined Undo/Redo bytes cannot exceed twice that limit. Resource references
/// are limited to 1,000 distinct values per effect and 10,000 per delivery, with
/// aggregate key storage also bounded by the payload budget. Validate the host's
/// evidence before effect acceptance: malformed accepted evidence suspends the
/// scope instead of retracting the domain change.
public struct HistoryEffect: Equatable, Sendable {
    /// Identity of the delivered member whose accepted effect this evidence describes.
    public let memberID: UUID
    /// Host-authored compensation input for this accepted member.
    public let undo: HistoryPayload
    /// Host-authored reapplication input for this accepted member.
    public let redo: HistoryPayload
    /// Opaque dependencies of this accepted effect, including versions required by recovery.
    public let resources: [HistoryObjectReference]

    /// Describes one authoritative accepted effect.
    /// Secure resources and persist sufficient evidence with the domain mutation before returning acceptance.
    /// The complete outcome must contain exactly one effect per delivered member, in delivery order.
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
    /// The complete delivery took effect atomically; evidence must survive interruption.
    /// Supply exactly one bounded effect per member in delivery order, including for Undo.
    case accepted([HistoryEffect])
    /// Authoritative proof that no member took effect. No accepted Action is created.
    case rejected
    /// Neither acceptance nor no-effect can be proven. Suspend the scope and preserve evidence.
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
    /// History persistence or finalization failed; consult stage and disposition before retrying.
    case storage
    /// An input, queue, plan or store safety bound would be exceeded.
    case capacity
    /// A Command, generation, working identity or registered location has a conflicting binding.
    case identityConflict
    /// The request violates structural requirements before semantic execution.
    case invalidInput
    /// Host evidence violates the complete-group acceptance contract.
    case hostProtocol
    /// The authoritative effect cannot yet be established.
    case unresolved
    /// Work, closure, maintenance or prohibited reentry prevents admission now.
    case busy
    /// A schema, codec, encoded envelope or stored model cannot be interpreted safely.
    case compatibility
    /// A cancellable pre-delivery operation or read was cancelled.
    case cancelled
    /// A host expected registered history, but no database exists at that location.
    case missingHistory
    /// Existing bytes are not a readable SQLite history database.
    case corruptHistory
    /// The expected location exists but cannot currently be opened.
    case unavailableStore
}

/// The transaction stage at which completion failed.
public enum HistoryFailureStage: String, Sendable {
    /// Admission, input validation or scheduling did not complete.
    case admission
    /// Durable preparation or the pre-delivery transition failed.
    case preparation
    /// The host delivery boundary failed to establish ordinary completion.
    case delivery
    /// Authoritative outcome lookup or interrupted-work recovery failed.
    case reconciliation
    /// History acceptance, rejection closure or related relationships could not finalize.
    case finalization
}
/// Whether this scope can continue accepting semantic mutations.
public enum HistoryScopeDisposition: String, Sendable {
    /// Safe closure or a pre-effect refusal permits subsequent independent requests.
    case usable
    /// Resolve evidence, prerequisites or finalization before allowing new semantic delivery.
    case suspended
    /// This generation cannot safely continue; the host must explicitly adopt coherent current state.
    case resetRequired
}

/// A typed failure. Underlying text is diagnostic and never changes the disposition.
public struct HistoryFailure: Error, Equatable, Sendable {
    /// Application-neutral category for diagnosis and recovery selection.
    public let cause: HistoryFailureCause
    /// Boundary at which successful framework completion stopped.
    public let stage: HistoryFailureStage
    /// Whether ordinary history use can continue; this outranks diagnostic text.
    public let disposition: HistoryScopeDisposition
    /// Optional diagnostic detail; it is neither a semantic rejection nor repair authorization.
    public let underlyingDescription: String?

    /// Creates a failure description. It does not alter scope state or reconcile domain effects.
    /// A host reports pre-effect failure only when no semantic effect is authoritative;
    /// possible effects require outcome lookup rather than classification as rejection.
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
    /// Durable transaction identity whose outcome and history relationships finalized.
    public let token: HistoryToken
    /// Whole-group identity referenced by structural history and restoration tools.
    public let groupID: UUID

    /// Rebuilds receipt metadata. Only an engine’s accepted result establishes completion.
    public init(token: HistoryToken, groupID: UUID) {
        self.token = token
        self.groupID = groupID
    }
}

/// Completion for one queued request. Rejected means authoritative no-effect.
public enum HistoryResult: Equatable, Sendable {
    /// Host effect and history finalization completed; Recording Off retains only session Undo.
    case accepted(HistoryReceipt)
    /// Authoritative no-effect, including an unavailable inverse; no accepted Action is created.
    case rejected
    /// Completion failed. Inspect disposition; failure after delivery does not prove no-effect.
    case failure(HistoryFailure)
}

/// Coherent ordinary availability after the latest completed engine transition.
/// Version increments when these values change within an open engine session.
public struct HistorySnapshot: Equatable, Sendable {
    /// Attached host scope, or nil for an unbound presentation snapshot.
    public let scope: UUID?
    /// Attached continuity boundary, or nil before a scope is bound.
    public let generation: UUID?
    /// Monotonic availability version within one open engine; restarts on a new session.
    public let version: Int64
    /// Whether a complete eligible Undo group is presently available.
    public let canUndo: Bool
    /// Whether a complete eligible Redo group is presently available.
    public let canRedo: Bool
    /// Unresolved evidence or failed persistence blocks ordinary mutation.
    public let isSuspended: Bool
    /// Queued or executing work remains; admission alone is not durable acceptance.
    public let hasPending: Bool

    /// Creates immutable availability metadata for presentation.
    /// Values do not grant permission to bypass engine admission or finalization checks.
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
    /// Positive byte budget for an inline payload and aggregate Command inputs; ceiling 64 MiB.
    public var maxPayloadBytes: Int
    /// Maximum members in one atomic delivery; positive, at most 1,000.
    public var maxMembers: Int
    /// Maximum waiting requests per scope, excluding its active request; positive, at most 1,024.
    public var maxQueueDepth: Int
    /// Positive physical history capacity including sidecars and reserves; ceiling 4 TiB.
    public var maxStoreBytes: Int64
    /// Shared ordinary Undo/Redo depth in original complete groups; positive, at most 100,000.
    public var maxUndoGroups: Int
    /// Maximum records in a bounded read or consolidation batch; positive, at most 1,000.
    public var maxReadPage: Int
    /// Maximum simultaneous protected Recovery Plans per scope; positive, at most 1,024.
    public var maxRecoveryPlans: Int

    /// Selects provisional limits; opening validates every value against compiled ceilings.
    /// Defaults are safeguards, not evidence that production workloads at each ceiling are calibrated.
    /// A retained-history target is separate from hard capacity and ordinary Undo depth.
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
public enum HistoryEntryKind: String, Sendable {
    /// Accepted original intent, including a host-authored restoration Command.
    case command
    /// Accepted compensation linked to an earlier original group.
    case undo
    /// Accepted reapplication linked to the original and its compensation.
    case redo
}

/// Structural history metadata. Reading an entry never decodes its host payload.
public struct HistoryEntry: Equatable, Sendable {
    /// Identity of this immutable accepted group.
    public let groupID: UUID
    /// Scope chronology position; checkpoints and rejected requests may occupy other positions.
    public let sequence: Int64
    /// Original execution, compensation or reapplication role.
    public let kind: HistoryEntryKind
    /// Original group compensated or reapplied by this entry; nil for ordinary Commands.
    public let sourceGroupID: UUID?
    /// Earlier compensation associated with an accepted Redo, when present.
    public let compensationGroupID: UUID?
    /// Host-authored historical provenance of a restoration Command.
    public let restorationOrigin: UUID?
    /// Number of accepted members in the complete group; payloads are read separately.
    public let memberCount: Int
    /// Framework recording time, without changing the host’s domain timestamps.
    public let recordedAt: Date

    /// Creates structural metadata without retrieving payloads or moving live Undo position.
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
    /// Stable checkpoint identity used for state lookup and state holds.
    public let id: UUID
    /// Optional host-selected display name, at most 4 KiB of UTF-8; not needed for reconstruction.
    public let name: String?
    /// Scope chronology position at which the coherent checkpoint was recorded.
    public let sequence: Int64
    /// Framework recording time for the checkpoint.
    public let recordedAt: Date

    /// Creates metadata without fetching state or securing its dependencies.
    public init(id: UUID, name: String?, sequence: Int64, recordedAt: Date) {
        self.id = id
        self.name = name
        self.sequence = sequence
        self.recordedAt = recordedAt
    }
}

/// A host-authored coherent historical state and its durable metadata.
public struct HistoryCheckpoint: Equatable, Sendable {
    /// Checkpoint identity and structural metadata.
    public let info: HistoryCheckpointInfo
    /// Opaque coherent state; engine lookup verifies its integrity and the host validates its meaning.
    public let state: HistoryPayload

    /// Pairs checkpoint metadata and state without executing restoration.
    /// To restore, validate the state in the host and submit a new Command.
    public init(info: HistoryCheckpointInfo, state: HistoryPayload) {
        self.info = info
        self.state = state
    }
}
