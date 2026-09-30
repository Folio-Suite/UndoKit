// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Darwin
import Foundation

/// How a scope is registered inside an already open physical history store.
public enum HistoryScopeOpenMode: Sendable { case create, existing }

/// Whether a store session can change history or only inspect its durable records.
public enum HistoryStoreAccess: Sendable { case readWrite, readOnly }

/// Measured on-disk history bytes and configured headroom for future writes.
public struct HistoryStoreFootprint: Equatable, Sendable {
    /// Current size of the main SQLite file, excluding its live sidecars.
    public let databaseBytes: Int64
    /// Current write-ahead log size.
    public let journalBytes: Int64
    /// Current SQLite shared-memory sidecar size.
    public let sharedMemoryBytes: Int64
    /// Closed copy size while its host capture callback is active; zero otherwise.
    public let temporaryMaintenanceBytes: Int64
    /// Conservative write reserve, capped by configured store capacity; not free disk.
    public let estimatedWorkingHeadroomBytes: Int64
    /// Sum of measured history files and the active maintenance copy.
    public var totalBytes: Int64 {
        databaseBytes + journalBytes + sharedMemoryBytes + temporaryMaintenanceBytes
    }
}

/// Read-only structural state for one registered scope. Pending recovery
/// records remain visible without invoking a host or guessing an outcome.
public struct HistoryScopeInspection: Equatable, Sendable {
    /// Registered host scope identity.
    public let scope: UUID
    /// Current continuity boundary for this scope.
    public let generation: UUID
    /// Whether scope evidence requires reconciliation before normal history use.
    public let isSuspended: Bool
    /// Transactions without a finalized accepted, rejected or cancelled outcome.
    public let pendingRecoveryCount: Int
}

/// Physical owner of a registered SQLite history store and its independent scopes.
/// The host chooses and coordinates the location. A writable session holds one
/// exclusive owner lock; readers may inspect committed records concurrently.
@MainActor public final class HistoryStore {
    @TaskLocal static var deliveringStores: Set<ObjectIdentifier> = []
    #if DEBUG
    @TaskLocal static var failInitialRegistrationSave = false
    #endif
    /// Canonical registered physical store URL; file coordination remains host-owned.
    public let url: URL
    /// Identity of the host document or app-owned data associated with this store.
    public let workingIdentity: UUID
    public internal(set) var storeIdentity: UUID
    /// Session access selected at opening and fixed until closure.
    public let access: HistoryStoreAccess
    let limits: HistoryLimits
    let container: NSPersistentContainer
    var lockDescriptor: Int32
    var engines: [UUID: HistoryEngine] = [:]
    var closing = false
    var closed = false
    var maintenance = false
    var activeMaintenanceURL: URL?
    var writeFailed = false
    var context: NSManagedObjectContext { container.viewContext }

    private init(url: URL, workingIdentity: UUID, storeIdentity: UUID,
                 access: HistoryStoreAccess, limits: HistoryLimits,
                 container: NSPersistentContainer, lockDescriptor: Int32) {
        self.url = url
        self.workingIdentity = workingIdentity
        self.storeIdentity = storeIdentity
        self.access = access
        self.limits = limits
        self.container = container
        self.lockDescriptor = lockDescriptor
    }

    deinit {
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
    }

    /// Opens a physical store without substituting an empty database for missing history.
    /// Read-only opening neither creates directories nor an owner file.
    /// - Parameters:
    ///   - requestedURL: Host-coordinated file location; no fallback store is created.
    ///   - workingIdentity: Stable identity of the corresponding host data.
    ///   - mode: Explicit creation, existing open, or adoption of an independent copy.
    ///   - access: Writable ownership or inspection without command delivery.
    ///   - limits: Per-store bounds inherited by its scopes.
    /// - Returns: An open session that the host must explicitly close.
    /// - Throws: Invalid bounds, identity or owner conflict, missing/corrupt history,
    ///   unavailable storage or incompatible model. Existing data is not reset.
    public static func open(at requestedURL: URL, workingIdentity: UUID,
                            mode: HistoryOpenMode, access: HistoryStoreAccess = .readWrite,
                            limits: HistoryLimits = HistoryLimits()) async throws -> HistoryStore {
        guard valid(limits) else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        let url = requestedURL.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: url.path)
        switch mode {
        case .create:
            guard access == .readWrite, !exists else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        case .existing, .independentCopy:
            guard exists else {
                throw HistoryFailure(.missingHistory, stage: .admission, disposition: .usable)
            }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                guard try handle.read(upToCount: 16) == Data("SQLite format 3\0".utf8) else {
                    throw HistoryFailure(.corruptHistory, stage: .admission, disposition: .usable)
                }
            } catch let failure as HistoryFailure {
                throw failure
            } catch {
                throw HistoryFailure(.unavailableStore, stage: .admission, disposition: .usable,
                                     underlyingDescription: String(describing: error))
            }
            if case .independentCopy = mode, access != .readWrite {
                throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
            }
        }
        var descriptor: Int32 = -1
        if access == .readWrite {
            descriptor = Darwin.open(url.appendingPathExtension("owner").path,
                                     O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw HistoryFailure(.unavailableStore, stage: .admission, disposition: .usable)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(descriptor)
                throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
            }
        }
        if case .create = mode, manager.fileExists(atPath: url.path) {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
        let artifacts = Self.storeArtifactURLs(at: url)
        let preexistingArtifacts = Set(artifacts.filter { manager.fileExists(atPath: $0.path) })
        var owned = descriptor >= 0
        var openedStore: HistoryStore?
        do {
            let container = try makeContainer(at: url, readOnly: access == .readOnly)
            let store = HistoryStore(url: url, workingIdentity: workingIdentity,
                                     storeIdentity: UUID(), access: access, limits: limits,
                                     container: container, lockDescriptor: descriptor)
            openedStore = store
            owned = false
            try store.register(mode: mode)
            return store
        } catch {
            if case .create = mode {
                do {
                    if let openedStore {
                        try openedStore.removeFailedCreationArtifacts(preexisting: preexistingArtifacts)
                    } else {
                        try Self.removeCreatedArtifacts(at: url, preexisting: preexistingArtifacts)
                    }
                } catch let cleanupError {
                    if owned { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
                    throw HistoryFailure(.storage, stage: .admission, disposition: .suspended,
                        underlyingDescription: "Creation failed: \(error). " +
                            "Cleanup preserved artifacts: \(cleanupError)")
                }
            }
            if owned { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
            throw error
        }
    }

    /// Stable Application Support placement for an app-owned history database.
    /// A host without an application identity supplies an explicit namespace.
    public static func applicationSupportURL(storeName: String, namespace: String? = nil) throws -> URL {
        let identity = namespace ?? Bundle.main.bundleIdentifier
        guard let identity, safePathComponent(identity), safePathComponent(storeName) else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: false)
        return base.appendingPathComponent(identity, isDirectory: true)
            .appendingPathComponent("UndoKit", isDirectory: true)
            .appendingPathComponent(storeName + ".sqlite")
    }

}

extension HistoryStore {
    /// Registers or reopens one scope. Each scope has its own host and ordered queue.
    public func openScope(_ scope: UUID, mode: HistoryScopeOpenMode,
                          host: any HistoryHost) async throws -> HistoryEngine {
        guard access == .readWrite, !closing, !closed, !maintenance, !writeFailed,
              engines[scope] == nil else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        let engine = HistoryEngine(store: self, scope: scope, limits: limits, host: host)
        do {
            try engine.register(mode: mode)
            engine.sessionStartSequence = try engine.scopeRecord().int64("nextSequence")
            engines[scope] = engine
            await engine.reconcileOnOpen()
            try engine.refreshSnapshot()
            try engine.releaseSessionReferences()
            return engine
        } catch {
            context.rollback()
            engines.removeValue(forKey: scope)
            throw error
        }
    }

    /// Reads committed group metadata from a reader session without a host adapter.
    public func historyPage(scope: UUID, after sequence: Int64? = nil,
                            limit: Int) throws -> [HistoryEntry] {
        guard !closed else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        guard limit > 0, limit <= limits.maxReadPage else {
            throw HistoryFailure(.capacity, stage: .admission, disposition: .usable)
        }
        _ = try inspectScope(scope)
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryGroupRecord")
        request.predicate = NSPredicate(format: "scopeKey == %@ AND sequence > %@",
                                        scope.uuidString, NSNumber(value: sequence ?? 0))
        request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: true)]
        request.fetchLimit = limit
        return try context.fetch(request).map { row in
            HistoryEntry(groupID: try row.uuid("key"), sequence: row.int64("sequence"),
                         kind: HistoryEntryKind(rawValue: row.string("kind") ?? "") ?? .command,
                         sourceGroupID: row.string("sourceGroupID").flatMap(UUID.init(uuidString:)),
                         compensationGroupID: row.string("compensationGroupID").flatMap(UUID.init(uuidString:)),
                         restorationOrigin: row.string("restorationOrigin").flatMap(UUID.init(uuidString:)),
                         memberCount: Int(row.int64("memberCount")),
                         recordedAt: row.value(forKey: "recordedAt") as? Date ?? .distantPast)
        }
    }

    /// Inspects a scope even when its unresolved transaction prevents mutation.
    public func inspectScope(_ scope: UUID) throws -> HistoryScopeInspection {
        guard !closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        if access == .readOnly { context.refreshAllObjects() }
        let scopeRequest = NSFetchRequest<NSManagedObject>(entityName: "HistoryScopeRecord")
        scopeRequest.predicate = NSPredicate(format: "key == %@", scope.uuidString)
        scopeRequest.fetchLimit = 1
        guard let row = try context.fetch(scopeRequest).first else {
            throw HistoryFailure(.missingHistory, stage: .admission, disposition: .usable)
        }
        let pending = NSFetchRequest<NSManagedObject>(entityName: "HistoryTransactionRecord")
        pending.predicate = NSPredicate(format: "scopeKey == %@ AND stage != %@ AND stage != %@ AND stage != %@",
            scope.uuidString, "accepted", "rejected", "cancelled")
        let generation = try row.uuid("generationID")
        return HistoryScopeInspection(scope: scope, generation: generation,
                                      isSuspended: row.bool("suspended"),
                                      pendingRecoveryCount: try context.count(for: pending))
    }

    /// Measures SQLite's database and live sidecars. Payloads and recovery rows
    /// reside in these files; host-owned referenced resources are excluded.
    public func physicalFootprint() -> HistoryStoreFootprint {
        let manager = FileManager.default
        func size(_ path: String) -> Int64 {
            (try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        return HistoryStoreFootprint(databaseBytes: size(url.path),
            journalBytes: size(url.path + "-wal"),
            sharedMemoryBytes: size(url.path + "-shm"),
            temporaryMaintenanceBytes: activeMaintenanceURL.map { size($0.path) } ?? 0,
            estimatedWorkingHeadroomBytes: min(limits.maxStoreBytes,
                                                Int64(limits.maxPayloadBytes) * 4 + 1_048_576))
    }

    func noteWriteFailure() {
        guard !writeFailed else { return }
        writeFailed = true
        for engine in engines.values {
            engine.publishSnapshot(canUndo: false, canRedo: false, isSuspended: true,
                                   hasPending: engine.draining || !engine.queue.isEmpty,
                                   generation: engine.snapshot.generation)
        }
    }

    /// Gives the host a coherent closed SQLite copy while admission is stopped
    /// across every scope. The host captures matching domain state and resources
    /// in `capture` before the boundary is released.
    /// - Parameters:
    ///   - destination: A new file path; an existing file is never replaced.
    ///   - capture: Host capture performed while all store admissions remain fenced.
    /// - Throws: Busy/reentrant/failed store, unresolved evidence, insufficient capacity,
    ///   cancellation while draining, copy failure, or the host callback's error.
    /// A failed callback leaves the completed copy at the destination for the host
    /// to manage. Cancellation after capture starts is cooperatively host-owned.
    /// The admission fence is released on every exit; source history stays intact.
    public func withCoordinatedCopy(
        to destination: URL,
        capture: @MainActor (URL) async throws -> Void
    ) async throws {
        guard access == .readWrite, !closed, !closing, !maintenance, !writeFailed,
              !Self.deliveringStores.contains(ObjectIdentifier(self)) else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        maintenance = true
        defer { maintenance = false }
        while engines.values.contains(where: { $0.draining || !$0.queue.isEmpty || $0.reconciling }) {
            if Task.isCancelled {
                throw HistoryFailure(.cancelled, stage: .admission, disposition: .usable)
            }
            await Task.yield()
        }
        if Task.isCancelled { throw HistoryFailure(.cancelled, stage: .admission, disposition: .usable) }
        try copyIdle(to: destination)
        activeMaintenanceURL = destination
        defer { activeMaintenanceURL = nil }
        try await capture(destination)
    }

    /// Convenience for a host that already holds its own matching capture fence.
    public func copy(to destination: URL) async throws {
        try await withCoordinatedCopy(to: destination) { _ in }
    }

    /// Stops all scope admission, waits for delivered work, then releases the owner.
    public func close() async throws {
        guard !closed else { return }
        guard !maintenance else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        guard !Self.deliveringStores.contains(ObjectIdentifier(self)) else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        closing = true
        let activeEngines = Array(engines.values)
        for engine in activeEngines { engine.beginClosing() }
        for engine in activeEngines { try await engine.close() }
        do {
            if access == .readWrite { try context.save() }
            let coordinator = container.persistentStoreCoordinator
            for persistentStore in coordinator.persistentStores { try coordinator.remove(persistentStore) }
        } catch {
            if access == .readWrite { context.rollback(); noteWriteFailure() }
            throw HistoryFailure(.storage, stage: .finalization, disposition: .suspended,
                                 underlyingDescription: String(describing: error))
        }
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); Darwin.close(lockDescriptor); lockDescriptor = -1 }
        closed = true
    }
}
