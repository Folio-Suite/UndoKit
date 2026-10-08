// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Whether a registered history file is new, reopened, or an independent working copy.
public enum HistoryOpenMode: Sendable {
    /// Create a new writable history file; an existing database is a conflict.
    case create
    /// Open existing compatible history bound to the supplied working identity.
    case existing
    /// Adopt a closed coordinated copy under a different working identity.
    /// The associated identity must match the copied source's durable registration.
    case independentCopy(sourceWorkingIdentity: UUID)
}

/// An open History Scope and its lifecycle controls.
///
/// Pass this session as `any HistoryTransactions` to ordinary editing code.
/// Pass `HistoryReading` to browsers and `HistoryRetentionManaging` to retention
/// policy code. Keep the concrete session for recording, generation and closure.
/// Host outcomes remain authoritative on the host's actor.
@MainActor public final class HistoryEngine: HistoryTransactions, HistoryReading, HistoryRetentionManaging {
    let history: HistoryScopeStorage
    let transaction: HistoryTransactionCoordinator
    let retained: RetainedHistory
    var ownsConvenienceStore = false

    /// Latest scope/generation availability; queued admission is not durable acceptance.
    public var snapshot: HistorySnapshot { transaction.snapshot }
    /// One host-owned observer for coherent availability changes on the main actor.
    public var snapshotDidChange: (@MainActor (HistorySnapshot) -> Void)? {
        get { transaction.snapshotDidChange }
        set { transaction.snapshotDidChange = newValue }
    }

    init(store: HistoryStore, scope: UUID, limits: HistoryLimits, host: any HistoryHost) {
        let history = HistoryScopeStorage(store: store, scope: scope, limits: limits)
        self.history = history
        let transaction = HistoryTransactionCoordinator(history: history, host: host)
        self.transaction = transaction
        retained = RetainedHistory(history: history, activity: transaction)
    }

    /// Opens only the requested store. Existing history is never replaced by a new empty store.
    /// A copied store requires an explicit source and new working identity. Opening reconciles
    /// interrupted transactions with the host before exposing ordinary Undo or Redo.
    public static func open(at url: URL, scope: UUID, workingIdentity: UUID,
                            mode: HistoryOpenMode, host: any HistoryHost,
                            limits: HistoryLimits = HistoryLimits()) async throws -> HistoryEngine {
        let store = try await HistoryStore.open(at: url, workingIdentity: workingIdentity,
                                                mode: mode, limits: limits)
        do {
            let scopeMode: HistoryScopeOpenMode
            switch mode {
            case .create: scopeMode = .create
            case .existing, .independentCopy: scopeMode = .existing
            }
            let engine = try await store.openScope(scope, mode: scopeMode, host: host)
            engine.ownsConvenienceStore = true
            return engine
        } catch {
            try? await store.close()
            throw error
        }
    }

    /// Enqueues a semantic Command. Completion follows durable finalization.
    /// Admission order is FIFO within this scope. Cancellation before preparation removes a
    /// waiting request; after delivery begins, host outcome reconciliation continues.
    public func submit(_ command: HistoryCommand) async -> HistoryResult {
        await transaction.enqueue(.command(command))
    }

    /// Reverses the latest eligible complete Undo Group through one host delivery.
    /// Rejection invalidates the affected group without creating an Action.
    public func undo(expectedGeneration: UUID? = nil) async -> HistoryResult {
        await transaction.enqueue(.undo(expectedGeneration: expectedGeneration))
    }

    /// Reapplies the next eligible complete Undo Group through one host delivery.
    public func redo(expectedGeneration: UUID? = nil) async -> HistoryResult {
        await transaction.enqueue(.redo(expectedGeneration: expectedGeneration))
    }

    /// Consults host evidence without redelivering a possibly started operation.
    /// Nil means no unresolved transaction remained to reconcile.
    public func reconcile() async -> HistoryResult? { await transaction.reconcile() }
}
