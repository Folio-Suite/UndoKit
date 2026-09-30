// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Darwin
import Foundation

/// Whether a registered history file is new, reopened, or an independent working copy.
public enum HistoryOpenMode: Sendable {
    case create
    case existing
    case independentCopy(sourceWorkingIdentity: UUID)
}

/// A serialized, durable history for one host-defined scope.
///
/// The host records a token and its accepted domain effect atomically. Every
/// callback is main-actor isolated; it must not submit another request to this
/// engine before the callback returns.
@MainActor public final class HistoryEngine {
    /// Called after a coherent availability change, following durable finalization.
    public var snapshotDidChange: (@MainActor (HistorySnapshot) -> Void)?
    /// The latest availability projection, including scope and generation identity.
    public internal(set) var snapshot = HistorySnapshot(
        canUndo: false, canRedo: false, isSuspended: false, hasPending: false
    )

    enum Request {
        case command(HistoryCommand)
        case undo
        case redo
    }

    struct Waiting {
        let id: UUID
        let request: Request
        let continuation: CheckedContinuation<HistoryResult, Never>
    }

    let store: HistoryStore
    var url: URL { store.url }
    let scope: UUID
    let limits: HistoryLimits
    let host: any HistoryHost
    var container: NSPersistentContainer { store.container }
    var context: NSManagedObjectContext { container.viewContext }
    var queue: [Waiting] = []
    var draining = false
    var closing = false
    var closed = false
    var reconciling = false
    var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(store: HistoryStore, scope: UUID, limits: HistoryLimits, host: any HistoryHost) {
        self.store = store
        self.scope = scope
        self.limits = limits
        self.host = host
    }

    var ownsConvenienceStore = false

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
            switch mode { case .create: scopeMode = .create; case .existing, .independentCopy: scopeMode = .existing }
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
        await enqueue(.command(command))
    }

    /// Reverses the latest eligible complete Undo Group through one host delivery.
    /// Rejection invalidates the affected group without creating an Action.
    public func undo() async -> HistoryResult { await enqueue(.undo) }

    /// Reapplies the next eligible complete Undo Group through one host delivery.
    public func redo() async -> HistoryResult { await enqueue(.redo) }

    func enqueue(_ request: Request) async -> HistoryResult {
        guard !HistoryHostCallbackContext.activeEngines.contains(ObjectIdentifier(self)) else {
            return .failure(HistoryFailure(.busy, stage: .admission, disposition: .usable))
        }
        if Task.isCancelled {
            return .failure(HistoryFailure(.cancelled, stage: .admission, disposition: .usable))
        }
        guard !closed, !closing, !reconciling, !store.closing, !store.closed,
              !store.maintenance else {
            return .failure(HistoryFailure(.busy, stage: .admission, disposition: .usable))
        }
        guard queue.count < limits.maxQueueDepth else {
            return .failure(HistoryFailure(.capacity, stage: .admission, disposition: .usable))
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.append(Waiting(id: id, request: request, continuation: continuation))
                updateSnapshot()
                if !draining {
                    draining = true
                    Task { await drain() }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelQueued(id) }
        }
    }

    func cancelQueued(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiting = queue.remove(at: index)
        waiting.continuation.resume(returning: .failure(
            HistoryFailure(.cancelled, stage: .admission, disposition: .usable)
        ))
        updateSnapshot()
    }

    func drain() async {
        while !queue.isEmpty {
            let waiting = queue.removeFirst()
            let result = await execute(waiting.request)
            waiting.continuation.resume(returning: result)
            updateSnapshot()
        }
        draining = false
        updateSnapshot()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
