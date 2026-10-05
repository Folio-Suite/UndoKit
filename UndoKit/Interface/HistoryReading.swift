// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Bounded historical reads, presentation and host-directed reconstruction.
///
/// Pass this capability to history browsers. Recovery Plans temporarily protect
/// material until release, cancellation or scope closure; this capability does
/// not imply a read-only physical store. Hosts interpret all payloads and own
/// reconstruction. Reading never delivers a command or moves the Undo position.
@MainActor public protocol HistoryReading: AnyObject, Sendable {
    // MARK: - Checkpoints and history

    /// Fetches and verifies one opaque checkpoint state, or returns nil if absent.
    func checkpoint(id: UUID) throws -> HistoryCheckpoint?

    /// Returns only metadata; state bytes require a separate checkpoint lookup.
    /// The page size cannot exceed the configured maximum.
    func checkpoints(after sequence: Int64?, limit: Int) throws -> [HistoryCheckpointInfo]

    /// Returns committed structural history in bounded pages without decoding host payloads.
    func historyPage(after sequence: Int64?, limit: Int) throws -> [HistoryEntry]

    // MARK: - Presentation

    /// Identity and accepted position observed together on this scope's actor.
    func readIdentity() throws -> HistoryReadIdentity

    /// Retrieves only a small encoded display value; absent data uses a generic label.
    func presentation(forGroup id: UUID) throws -> HistoryPayload?

    /// Resolve native menu names through the host's metadata codec. The returned
    /// snapshot and names are read in one actor turn for `NativeHistoryRouter.update`.
    func nativeActionNames(
        resolve: (HistoryPayload) throws -> String?
    ) throws -> (snapshot: HistorySnapshot, names: HistoryNativeActionNames)

    // MARK: - Reconstruction

    /// Plans protect their sequence interval until explicit release or session close.
    /// The host captures the current domain baseline before requesting `.current`.
    /// - Parameters:
    ///   - source: Coherent current domain state or a stored checkpoint baseline.
    ///   - target: Accepted group state or complete checkpoint to reconstruct.
    ///   - evidence: Explicit host promise that accepted effects represent state transitions.
    /// - Returns: A session-bound handle; release it on success, failure or abandonment.
    /// - Throws: Busy/suspended scope, plan capacity, cancellation, missing target or retained gap.
    func beginRecoveryPlan(
        from source: HistoryRecoverySource,
        to target: HistoryRecoveryTarget,
        using evidence: HistoryReconstructionEvidence
    ) throws -> HistoryRecoveryPlan

    /// Reads at most `limit` accepted transitions; no host payload is materialized.
    /// Pass only the preceding page's cursor for this handle. Throws for an invalid
    /// handle/cursor, limit, missing interval or cancellation. Cancellation releases
    /// the handle. Nil `nextCursor` means this traversal is complete.
    func recoveryPage(_ plan: HistoryRecoveryPlan, after cursor: Int64?,
                      limit: Int) throws -> HistoryRecoveryPage

    /// Fetches one intact opaque accepted-effect member from a plan step.
    /// `groupID` and `ordinal` must identify a member in this plan's interval.
    /// Throws on missing/corrupt material, invalid selection or cancellation;
    /// it never invokes the host or mutates live state.
    func recoveryMaterial(_ plan: HistoryRecoveryPlan, groupID: UUID,
                          ordinal: Int) throws -> HistoryRecoveryMaterial

    /// Returns a checkpoint baseline only if it belongs to this live plan.
    func recoveryCheckpoint(_ plan: HistoryRecoveryPlan) throws -> HistoryCheckpoint?

    /// Ends temporary retention protection. Releasing an already-ended handle is harmless.
    func releaseRecoveryPlan(_ plan: HistoryRecoveryPlan)

    /// Stops further reads and relinquishes temporary protection immediately.
    func cancelRecoveryPlan(_ plan: HistoryRecoveryPlan)
}

// MARK: - Reading conveniences

extension HistoryReading {
    /// Begins the checkpoint metadata listing at its first page.
    public func checkpoints(limit: Int) throws -> [HistoryCheckpointInfo] {
        try checkpoints(after: nil, limit: limit)
    }

    /// Begins the structural history listing at its first page.
    public func historyPage(limit: Int) throws -> [HistoryEntry] {
        try historyPage(after: nil, limit: limit)
    }

    /// Plans reconstruction from coherent current domain state captured by the host.
    /// Creates a fixed historical view with temporary retention protection.
    /// Capture coherent host state before using `.current` and promise that effects are reconstructible.
    /// Release on success, failure or abandonment. Missing targets, gaps, suspension,
    /// plan capacity and cancellation fail explicitly without executing a Command.
    public func beginRecoveryPlan(to target: HistoryRecoveryTarget,
                                  using evidence: HistoryReconstructionEvidence) throws -> HistoryRecoveryPlan {
        try beginRecoveryPlan(from: .current, to: target, using: evidence)
    }

    /// Reads the first bounded page of a live Recovery Plan.
    public func recoveryPage(_ plan: HistoryRecoveryPlan, limit: Int) throws -> HistoryRecoveryPage {
        try recoveryPage(plan, after: nil, limit: limit)
    }
}

// MARK: - Scope forwarding

extension HistoryEngine {
    /// Reads one integrity-checked opaque checkpoint, or nil if absent.
    /// The host decodes and validates its state; this never performs restoration.
    public func checkpoint(id: UUID) throws -> HistoryCheckpoint? {
        try retained.checkpoint(id: id)
    }

    /// Reads checkpoint metadata in increasing sequence order, strictly after the cursor.
    /// Pass the last returned sequence; the positive limit cannot exceed ``HistoryLimits/maxReadPage``.
    public func checkpoints(after sequence: Int64? = nil, limit: Int) throws -> [HistoryCheckpointInfo] {
        try retained.checkpoints(after: sequence, limit: limit)
    }

    /// Reads committed accepted-group metadata strictly after the sequence cursor.
    /// The positive limit cannot exceed ``HistoryLimits/maxReadPage``; host payloads remain opaque.
    public func historyPage(after sequence: Int64? = nil, limit: Int) throws -> [HistoryEntry] {
        try retained.historyPage(after: sequence, limit: limit)
    }

    /// Reads generation and committed position together without moving live Undo position.
    public func readIdentity() throws -> HistoryReadIdentity {
        try retained.readIdentity()
    }

    /// Reads bounded integrity-checked display metadata, or nil if absent.
    /// Unknown host presentation formats may use a generic label without blocking recovery.
    public func presentation(forGroup id: UUID) throws -> HistoryPayload? {
        try retained.presentation(forGroup: id)
    }

    /// Resolves host-authored menu labels and matching availability in one main-actor turn.
    /// The resolver interprets display payloads only; its errors propagate to the caller.
    public func nativeActionNames(
        resolve: (HistoryPayload) throws -> String?
    ) throws -> (snapshot: HistorySnapshot, names: HistoryNativeActionNames) {
        try retained.nativeActionNames(resolve: resolve)
    }

    /// Creates a fixed historical view with temporary retention protection.
    /// Capture coherent host state before using `.current` and promise that effects are reconstructible.
    /// Release on success, failure or abandonment. Missing targets, gaps, suspension,
    /// plan capacity and cancellation fail explicitly without executing a Command.
    public func beginRecoveryPlan(
        from source: HistoryRecoverySource = .current,
        to target: HistoryRecoveryTarget,
        using evidence: HistoryReconstructionEvidence
    ) throws -> HistoryRecoveryPlan {
        try retained.beginRecoveryPlan(from: source, to: target, using: evidence)
    }

    /// Reads bounded transition references in the plan direction without decoding host payloads.
    /// Use only this plan’s preceding cursor. Cancellation releases the plan; stale handles fail.
    public func recoveryPage(_ plan: HistoryRecoveryPlan, after cursor: Int64? = nil,
                             limit: Int) throws -> HistoryRecoveryPage {
        try retained.recoveryPage(plan, after: cursor, limit: limit)
    }

    /// Retrieves one integrity-checked member in this plan’s interval.
    /// Use valid zero-based ordinals and reconstruct on the host; live domain state is untouched.
    public func recoveryMaterial(_ plan: HistoryRecoveryPlan, groupID: UUID,
                                 ordinal: Int) throws -> HistoryRecoveryMaterial {
        try retained.recoveryMaterial(plan, groupID: groupID, ordinal: ordinal)
    }

    /// Retrieves the stored checkpoint baseline belonging to this live plan, if any.
    public func recoveryCheckpoint(_ plan: HistoryRecoveryPlan) throws -> HistoryCheckpoint? {
        try retained.recoveryCheckpoint(plan)
    }

    /// Releases temporary retention protection; repeating release is harmless.
    public func releaseRecoveryPlan(_ plan: HistoryRecoveryPlan) {
        retained.releaseRecoveryPlan(plan)
    }

    /// Ends this plan immediately and relinquishes its temporary retention protection.
    public func cancelRecoveryPlan(_ plan: HistoryRecoveryPlan) {
        retained.cancelRecoveryPlan(plan)
    }
}
