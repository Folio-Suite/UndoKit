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

    let url: URL
    let scope: UUID
    let limits: HistoryLimits
    let host: any HistoryHost
    let container: NSPersistentContainer
    var lockDescriptor: Int32
    var context: NSManagedObjectContext { container.viewContext }
    var queue: [Waiting] = []
    var draining = false
    var closing = false
    var closed = false
    var reconciling = false
    var closeWaiters: [CheckedContinuation<Void, Never>] = []

    private init(url: URL, scope: UUID, limits: HistoryLimits, host: any HistoryHost,
                 container: NSPersistentContainer, lockDescriptor: Int32) {
        self.url = url
        self.scope = scope
        self.limits = limits
        self.host = host
        self.container = container
        self.lockDescriptor = lockDescriptor
    }

    deinit {
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
    }

    /// Opens only the requested store. Existing history is never replaced by a new empty store.
    /// A copied store requires an explicit source and new working identity. Opening reconciles
    /// interrupted transactions with the host before exposing ordinary Undo or Redo.
    public static func open(at url: URL, scope: UUID, workingIdentity: UUID,
                            mode: HistoryOpenMode, host: any HistoryHost,
                            limits: HistoryLimits = HistoryLimits()) async throws -> HistoryEngine {
        guard limits.maxPayloadBytes > 0, limits.maxPayloadBytes <= 64 * 1024 * 1024,
              limits.maxMembers > 0, limits.maxMembers <= 1_000,
              limits.maxQueueDepth > 0, limits.maxQueueDepth <= 1_024,
              limits.maxStoreBytes > 0, limits.maxStoreBytes <= 4 * 1024 * 1024 * 1024 * 1024,
              limits.maxUndoGroups > 0, limits.maxUndoGroups <= 100_000,
              limits.maxReadPage > 0, limits.maxReadPage <= 1_000 else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let exists = manager.fileExists(atPath: url.path)
        switch mode {
        case .create where exists, .existing where !exists, .independentCopy where !exists:
            throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
        default:
            break
        }
        let lockURL = url.appendingPathExtension("owner")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw HistoryFailure(.storage, stage: .admission, disposition: .usable)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        var descriptorOwned = true
        do {
            #if SWIFT_PACKAGE
            let bundle = Bundle.module
            #else
            let bundle = Bundle(for: HistoryEngine.self)
            #endif
            guard let modelURL = bundle.url(forResource: "History", withExtension: "momd"),
                  let model = NSManagedObjectModel(contentsOf: modelURL) else {
                throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
            }
            let container = NSPersistentContainer(name: "History", managedObjectModel: model)
            let description = NSPersistentStoreDescription(url: url)
            description.type = NSSQLiteStoreType
            description.shouldAddStoreAsynchronously = false
            description.shouldMigrateStoreAutomatically = false
            description.shouldInferMappingModelAutomatically = false
            container.persistentStoreDescriptions = [description]
            var loadError: Error?
            container.loadPersistentStores { _, error in loadError = error }
            if let loadError {
                throw HistoryFailure(.storage, stage: .admission,
                                     disposition: .usable, underlyingDescription: String(describing: loadError))
            }
            let engine = HistoryEngine(url: url, scope: scope, limits: limits, host: host,
                                       container: container, lockDescriptor: descriptor)
            descriptorOwned = false
            try engine.register(workingIdentity: workingIdentity, mode: mode)
            await engine.reconcileOnOpen()
            try engine.refreshSnapshot()
            return engine
        } catch {
            if descriptorOwned {
                flock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
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
        if Task.isCancelled {
            return .failure(HistoryFailure(.cancelled, stage: .admission, disposition: .usable))
        }
        guard !closed, !closing, !reconciling else {
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
