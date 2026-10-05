// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Host-directed checkpoint, hold and consolidation operations for one History Scope.
///
/// The same scope owner backs this capability and `HistoryReading`, so active
/// Recovery Plans automatically protect the material they need. Physical-store
/// resource cleanup remains on `HistoryStore`.
@MainActor public protocol HistoryRetentionManaging: AnyObject, Sendable {
    // MARK: - Checkpoints and holds

    /// Records host-confirmed coherent state. The host secures its required resources first.
    /// Checkpoint creation is synchronous and requires an idle, usable scope.
    func createCheckpoint(
        id: UUID, name: String?, state: HistoryPayload,
        resources: [HistoryObjectReference]
    ) throws -> HistoryCheckpointInfo

    /// Holds one host-authored coherent checkpoint state until this hold is released.
    @discardableResult func holdState(_ checkpointID: UUID, id: UUID) throws -> HistoryRetentionHold

    /// Holds accepted groups between two structural endpoints, inclusive.
    /// Sequence holes from checkpoints and rejected commands are harmless;
    /// an existing removed-acceptance gap makes the hold impossible.
    @discardableResult func holdDetail(from firstGroupID: UUID, through lastGroupID: UUID,
                                       id: UUID) throws -> HistoryRetentionHold

    /// Releases only the named hold. Other holds and ordinary Undo protection remain.
    func releaseHold(_ id: UUID) throws

    /// Lists durable holds for the current History Generation.
    func retentionHolds() throws -> [HistoryRetentionHold]

    // MARK: - Consolidation

    /// Replaces eligible accepted detail before a host-confirmed checkpoint.
    /// Each call removes at most maxReadPage groups and checkpoints in one store
    /// transaction. The checkpoint carries the coherent state; no command replay
    /// or synthetic state inference occurs here.
    /// The scope must be idle and writable. Active plans, holds, current state
    /// identity, and the configured ordinary Undo/Redo depth stay protected.
    /// `targetUnmet` reports retained group count above the policy target;
    /// `hasMore` means another bounded pass can remove eligible material.
    /// Repeated calls may scan retained group metadata and can be expensive.
    /// Cancellation before commit rolls back that pass. A save failure suspends
    /// the physical store; inspect and reopen it before retrying. Removed
    /// resource references leave durable host cleanup work for
    /// `HistoryStore.withRequiredObjects(in:cleanup:)`.
    func consolidateHistory(through checkpointID: UUID,
                            policy: HistoryRetentionPolicy) throws -> HistoryConsolidationResult
}

// MARK: - Retention conveniences

extension HistoryRetentionManaging {
    /// Records a checkpoint with a fresh identity after the host secures its resources.
    /// Records opaque host-confirmed coherent state at an idle usable boundary.
    /// Secure resources first; a checkpoint does not save the host document or execute a Command.
    public func createCheckpoint(name: String?, state: HistoryPayload,
                                 resources: [HistoryObjectReference] = []) throws -> HistoryCheckpointInfo {
        try createCheckpoint(id: UUID(), name: name, state: state, resources: resources)
    }

    /// Records an explicitly identified checkpoint with no external resource references.
    /// Records opaque host-confirmed coherent state at an idle usable boundary.
    /// Secure resources first; a checkpoint does not save the host document or execute a Command.
    public func createCheckpoint(id: UUID, name: String?, state: HistoryPayload) throws -> HistoryCheckpointInfo {
        try createCheckpoint(id: id, name: name, state: state, resources: [])
    }

    /// Creates a fresh hold for one host-authored checkpoint state.
    /// Durably protects one checkpoint state and its dependencies until this hold is released.
    /// It does not preserve all preceding editing detail or extend ordinary Undo depth.
    @discardableResult public func holdState(_ checkpointID: UUID) throws -> HistoryRetentionHold {
        try holdState(checkpointID, id: UUID())
    }

    /// Creates a fresh hold for an inclusive interval of accepted groups.
    /// Durably protects complete accepted groups between the inclusive endpoints.
    /// An already removed accepted interval cannot be held; ordinary sequence holes are allowed.
    @discardableResult public func holdDetail(from firstGroupID: UUID,
                                              through lastGroupID: UUID) throws -> HistoryRetentionHold {
        try holdDetail(from: firstGroupID, through: lastGroupID, id: UUID())
    }
}

// MARK: - Scope forwarding

extension HistoryEngine {
    /// Records opaque host-confirmed coherent state at an idle usable boundary.
    /// Secure resources first; a checkpoint does not save the host document or execute a Command.
    public func createCheckpoint(
        id: UUID = UUID(), name: String?, state: HistoryPayload,
        resources: [HistoryObjectReference] = []
    ) throws -> HistoryCheckpointInfo {
        try retained.createCheckpoint(id: id, name: name, state: state, resources: resources)
    }

    /// Durably protects one checkpoint state and its dependencies until this hold is released.
    /// It does not preserve all preceding editing detail or extend ordinary Undo depth.
    @discardableResult public func holdState(_ checkpointID: UUID, id: UUID = UUID()) throws -> HistoryRetentionHold {
        try retained.holdState(checkpointID, id: id)
    }

    /// Durably protects complete accepted groups between the inclusive endpoints.
    /// An already removed accepted interval cannot be held; ordinary sequence holes are allowed.
    @discardableResult public func holdDetail(from firstGroupID: UUID, through lastGroupID: UUID,
                                              id: UUID = UUID()) throws -> HistoryRetentionHold {
        try retained.holdDetail(from: firstGroupID, through: lastGroupID, id: id)
    }

    /// Releases only the named durable promise; overlapping protection remains in force.
    public func releaseHold(_ id: UUID) throws {
        try retained.releaseHold(id)
    }

    /// Lists durable state and detail promises in the current generation.
    public func retentionHolds() throws -> [HistoryRetentionHold] {
        try retained.retentionHolds()
    }

    /// Atomically removes eligible detail before a coherent host checkpoint in a bounded pass.
    /// Depth, holds, current state and plans remain protected. Inspect `hasMore` and `targetUnmet`.
    /// This may scan retained metadata; save failure suspends the store and preserves recovery needs.
    /// See ``HistoryRetentionManaging/consolidateHistory(through:policy:)`` for policy and cleanup obligations.
    public func consolidateHistory(through checkpointID: UUID,
                                   policy: HistoryRetentionPolicy) throws -> HistoryConsolidationResult {
        try retained.consolidateHistory(through: checkpointID, policy: policy)
    }
}
