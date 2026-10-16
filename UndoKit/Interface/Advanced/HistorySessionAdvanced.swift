// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Focused lower-level capabilities fenced by the ordinary session's owner.
@MainActor public final class HistorySessionAdvanced: HistoryReading, HistoryRetentionManaging {
    weak var session: HistorySession?
    init(session: HistorySession) { self.session = session }
    private func engine(mutating: Bool = false) throws -> HistoryEngine {
        guard let session, let engine = session.engine, session.status.phase != .closed,
            session.status.phase != .closing
        else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        if mutating {
            guard session.status.phase == .ready, !session.status.requiresDraftDecision,
                try session.nativeCoordinator.capturePrerequisite() == nil
            else {
                throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
            }
            try engine.transaction.requireIdle()
        }
        return engine
    }
    public func submit(_ command: HistoryCommand) async -> HistorySubmissionResult {
        do { return HistorySubmissionResult(await (try engine()).submit(command)) } catch {
            return .unexecuted(HistorySession.describe(error, stage: .admission))
        }
    }
    public func checkpoint(id: UUID) throws -> HistoryCheckpoint? { try engine().checkpoint(id: id) }
    public func checkpoints(after sequence: Int64? = nil, limit: Int) throws -> [HistoryCheckpointInfo] {
        try engine().checkpoints(after: sequence, limit: limit)
    }
    public func historyPage(after sequence: Int64? = nil, limit: Int) throws -> [HistoryEntry] {
        try engine().historyPage(after: sequence, limit: limit)
    }
    public func readIdentity() throws -> HistoryReadIdentity { try engine().readIdentity() }
    public func presentation(forGroup id: UUID) throws -> HistoryPayload? { try engine().presentation(forGroup: id) }
    public func nativeActionNames(resolve: (HistoryPayload) throws -> String?) throws -> (
        snapshot: HistorySnapshot, names: HistoryNativeActionNames
    ) {
        try engine().nativeActionNames(resolve: resolve)
    }
    public func beginRecoveryPlan(
        from source: HistoryRecoverySource, to target: HistoryRecoveryTarget,
        using evidence: HistoryReconstructionEvidence
    ) throws -> HistoryRecoveryPlan {
        try engine(mutating: true).beginRecoveryPlan(from: source, to: target, using: evidence)
    }
    public func recoveryPage(_ plan: HistoryRecoveryPlan, after cursor: Int64? = nil, limit: Int) throws
        -> HistoryRecoveryPage {
        try engine().recoveryPage(plan, after: cursor, limit: limit)
    }
    public func recoveryMaterial(_ plan: HistoryRecoveryPlan, groupID: UUID, ordinal: Int) throws
        -> HistoryRecoveryMaterial {
        try engine().recoveryMaterial(plan, groupID: groupID, ordinal: ordinal)
    }
    public func recoveryCheckpoint(_ plan: HistoryRecoveryPlan) throws -> HistoryCheckpoint? {
        try engine().recoveryCheckpoint(plan)
    }
    public func releaseRecoveryPlan(_ plan: HistoryRecoveryPlan) { session?.engine?.releaseRecoveryPlan(plan) }
    public func cancelRecoveryPlan(_ plan: HistoryRecoveryPlan) { session?.engine?.cancelRecoveryPlan(plan) }
    public func createCheckpoint(
        id: UUID, name: String?, state: HistoryPayload,
        resources: [HistoryObjectReference]
    ) throws -> HistoryCheckpointInfo {
        try engine(mutating: true).createCheckpoint(id: id, name: name, state: state, resources: resources)
    }
    public func holdState(_ checkpointID: UUID, id: UUID) throws -> HistoryRetentionHold {
        try engine(mutating: true).holdState(checkpointID, id: id)
    }
    public func holdDetail(
        from firstGroupID: UUID, through lastGroupID: UUID, id: UUID
    ) throws -> HistoryRetentionHold {
        try engine(mutating: true).holdDetail(from: firstGroupID, through: lastGroupID, id: id)
    }
    public func releaseHold(_ id: UUID) throws { try engine(mutating: true).releaseHold(id) }
    public func retentionHolds() throws -> [HistoryRetentionHold] { try engine().retentionHolds() }
    public func consolidateHistory(through checkpointID: UUID, policy: HistoryRetentionPolicy) throws
        -> HistoryConsolidationResult {
        try engine(mutating: true).consolidateHistory(through: checkpointID, policy: policy)
    }
    public func recordingMode() throws -> HistoryRecordingMode { try engine().recordingMode() }
    @discardableResult public func setRecording(
        _ mode: HistoryRecordingMode, baseline: HistoryPayload? = nil,
        resources: [HistoryObjectReference] = []
    ) throws -> UUID? {
        try engine(mutating: true).setRecording(mode, baseline: baseline, resources: resources)
    }
    @discardableResult public func clearHistory(
        adopting baseline: HistoryPayload,
        resources: [HistoryObjectReference] = []
    ) throws -> UUID {
        let generation = try engine(mutating: true).clearHistory(adopting: baseline, resources: resources)
        try session?.retireGeneration()
        return generation
    }
    @discardableResult public func resetUnresolvedHistory(
        adopting baseline: HistoryPayload,
        resources: [HistoryObjectReference] = [], quarantineAt destination: URL
    ) throws -> UUID {
        guard let session, try session.nativeCoordinator.capturePrerequisite() == nil else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        let generation = try engine().resetUnresolvedHistory(
            adopting: baseline, resources: resources, quarantineAt: destination)
        try session.retireGeneration()
        return generation
    }
    public func requiredObjects(
        in retentionStore: UUID, after cursor: HistoryObjectReference? = nil,
        limit: Int
    ) throws -> HistoryRequiredObjectPage {
        try engine().store.requiredObjects(in: retentionStore, after: cursor, limit: limit)
    }
    public func withRequiredObjects(
        in retentionStore: UUID,
        cleanup: @MainActor (HistorySessionAdvanced) async throws -> Void
    ) async throws {
        let engine = try engine(mutating: true)
        try session?.storeOwner?.requireNativeIdle()
        try await engine.store.withRequiredObjects(in: retentionStore) { _ in try await cleanup(self) }
    }
    public func withCoordinatedCopy(
        to destination: URL,
        capture: @MainActor (URL) async throws -> Void
    ) async throws {
        let engine = try engine(mutating: true)
        try session?.storeOwner?.requireNativeIdle()
        try await engine.store.withCoordinatedCopy(to: destination, capture: capture)
    }
}
