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
    public func checkpoint(id: UUID) throws -> HistoryCheckpoint? {
        try retained.checkpoint(id: id)
    }

    public func checkpoints(after sequence: Int64? = nil, limit: Int) throws -> [HistoryCheckpointInfo] {
        try retained.checkpoints(after: sequence, limit: limit)
    }

    public func historyPage(after sequence: Int64? = nil, limit: Int) throws -> [HistoryEntry] {
        try retained.historyPage(after: sequence, limit: limit)
    }

    public func readIdentity() throws -> HistoryReadIdentity {
        try retained.readIdentity()
    }

    public func presentation(forGroup id: UUID) throws -> HistoryPayload? {
        try retained.presentation(forGroup: id)
    }

    public func nativeActionNames(
        resolve: (HistoryPayload) throws -> String?
    ) throws -> (snapshot: HistorySnapshot, names: HistoryNativeActionNames) {
        try retained.nativeActionNames(resolve: resolve)
    }

    public func beginRecoveryPlan(
        from source: HistoryRecoverySource = .current,
        to target: HistoryRecoveryTarget,
        using evidence: HistoryReconstructionEvidence
    ) throws -> HistoryRecoveryPlan {
        try retained.beginRecoveryPlan(from: source, to: target, using: evidence)
    }

    public func recoveryPage(_ plan: HistoryRecoveryPlan, after cursor: Int64? = nil,
                             limit: Int) throws -> HistoryRecoveryPage {
        try retained.recoveryPage(plan, after: cursor, limit: limit)
    }

    public func recoveryMaterial(_ plan: HistoryRecoveryPlan, groupID: UUID,
                                 ordinal: Int) throws -> HistoryRecoveryMaterial {
        try retained.recoveryMaterial(plan, groupID: groupID, ordinal: ordinal)
    }

    public func recoveryCheckpoint(_ plan: HistoryRecoveryPlan) throws -> HistoryCheckpoint? {
        try retained.recoveryCheckpoint(plan)
    }

    public func releaseRecoveryPlan(_ plan: HistoryRecoveryPlan) {
        retained.releaseRecoveryPlan(plan)
    }

    public func cancelRecoveryPlan(_ plan: HistoryRecoveryPlan) {
        retained.cancelRecoveryPlan(plan)
    }
}
