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
    public let databaseBytes: Int64
    public let journalBytes: Int64
    public let sharedMemoryBytes: Int64
    public let temporaryMaintenanceBytes: Int64
    public let estimatedWorkingHeadroomBytes: Int64
    public var totalBytes: Int64 {
        databaseBytes + journalBytes + sharedMemoryBytes + temporaryMaintenanceBytes
    }
}

/// Read-only structural state for one registered scope. Pending recovery
/// records remain visible without invoking a host or guessing an outcome.
public struct HistoryScopeInspection: Equatable, Sendable {
    public let scope: UUID
    public let generation: UUID
    public let isSuspended: Bool
    public let pendingRecoveryCount: Int
}

/// Physical owner of a registered SQLite history store and its independent scopes.
/// The host chooses and coordinates the location. A writable session holds one
/// exclusive owner lock; readers may inspect committed records concurrently.
@MainActor public final class HistoryStore {
    @TaskLocal static var deliveringStore: ObjectIdentifier? = nil
    public let url: URL
    public let workingIdentity: UUID
    public private(set) var storeIdentity: UUID
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
            } catch let failure as HistoryFailure { throw failure }
            catch {
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
        var owned = descriptor >= 0
        do {
            let container = try makeContainer(at: url, readOnly: access == .readOnly)
            let store = HistoryStore(url: url, workingIdentity: workingIdentity,
                                     storeIdentity: UUID(), access: access, limits: limits,
                                     container: container, lockDescriptor: descriptor)
            owned = false
            try store.register(mode: mode)
            return store
        } catch {
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

    private static func safePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".." &&
        !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private static func valid(_ limits: HistoryLimits) -> Bool {
        limits.maxPayloadBytes > 0 && limits.maxPayloadBytes <= 64 * 1024 * 1024 &&
        limits.maxMembers > 0 && limits.maxMembers <= 1_000 &&
        limits.maxQueueDepth > 0 && limits.maxQueueDepth <= 1_024 &&
        limits.maxStoreBytes > 0 && limits.maxStoreBytes <= 4 * 1024 * 1024 * 1024 * 1024 &&
        limits.maxUndoGroups > 0 && limits.maxUndoGroups <= 100_000 &&
        limits.maxReadPage > 0 && limits.maxReadPage <= 1_000
    }

    private static func makeContainer(at url: URL, readOnly: Bool) throws -> NSPersistentContainer {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: HistoryStore.self)
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
        if readOnly { description.setOption(true as NSNumber, forKey: NSReadOnlyPersistentStoreOption) }
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            throw HistoryFailure(openCause(for: loadError), stage: .admission, disposition: .usable,
                                 underlyingDescription: String(describing: loadError))
        }
        return container
    }

    private static func openCause(for error: Error) -> HistoryFailureCause {
        var current: NSError? = error as NSError
        while let problem = current {
            if problem.domain == NSCocoaErrorDomain &&
                (problem.code == NSPersistentStoreIncompatibleVersionHashError ||
                 problem.code == NSMigrationError) {
                return .compatibility
            }
            if problem.domain == NSSQLiteErrorDomain &&
                (problem.code == 11 || problem.code == 26) {
                return .corruptHistory
            }
            current = problem.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .unavailableStore
    }

    private func register(mode: HistoryOpenMode) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryStoreRecord")
        request.predicate = NSPredicate(format: "key == %@", "primary")
        request.fetchLimit = 1
        let record = try context.fetch(request).first
        switch mode {
        case .create:
            guard record == nil else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
            let created = NSEntityDescription.insertNewObject(forEntityName: "HistoryStoreRecord", into: context)
            created.setValue("primary", forKey: "key")
            created.setValue(workingIdentity.uuidString, forKey: "workingID")
            created.setValue(storeIdentity.uuidString, forKey: "storeID")
            do { try context.save() } catch { context.rollback(); throw error }
        case .existing:
            guard let record else {
                throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
            }
            guard record.string("workingID") == workingIdentity.uuidString,
                  let storeID = record.string("storeID").flatMap(UUID.init(uuidString:)) else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
            storeIdentity = storeID
        case .independentCopy(let sourceWorkingIdentity):
            guard let record, record.string("workingID") == sourceWorkingIdentity.uuidString,
                  sourceWorkingIdentity != workingIdentity else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
            let scopes = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "HistoryScopeRecord"))
            guard scopes.allSatisfy({ $0.string("workingID") == sourceWorkingIdentity.uuidString }) else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
            record.setValue(workingIdentity.uuidString, forKey: "workingID")
            record.setValue(storeIdentity.uuidString, forKey: "storeID")
            for scope in scopes { scope.setValue(workingIdentity.uuidString, forKey: "workingID") }
            do { try context.save() } catch { context.rollback(); throw error }
        }
    }

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
            engines[scope] = engine
            await engine.reconcileOnOpen()
            try engine.refreshSnapshot()
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
    public func withCoordinatedCopy(
        to destination: URL,
        capture: @MainActor (URL) async throws -> Void
    ) async throws {
        guard access == .readWrite, !closed, !closing, !maintenance, !writeFailed,
              Self.deliveringStore != ObjectIdentifier(self) else {
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

    func copyIdle(to destination: URL) throws {
        guard access == .readWrite, !closed, !closing,
              engines.values.allSatisfy({ !$0.draining && $0.queue.isEmpty && !$0.reconciling && !$0.snapshot.isSuspended }) else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
        let pending = NSFetchRequest<NSManagedObject>(entityName: "HistoryTransactionRecord")
        pending.predicate = NSPredicate(format: "stage != %@ AND stage != %@ AND stage != %@",
                                        "accepted", "rejected", "cancelled")
        pending.fetchLimit = 1
        guard try context.fetch(pending).isEmpty else {
            throw HistoryFailure(.unresolved, stage: .admission, disposition: .suspended)
        }
        let footprint = physicalFootprint()
        guard footprint.totalBytes <= limits.maxStoreBytes / 2 else {
            throw HistoryFailure(.capacity, stage: .admission, disposition: .usable,
                                 underlyingDescription: "Insufficient configured headroom for a full store copy")
        }
        if let available = try? destination.deletingLastPathComponent().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
           available < footprint.totalBytes + footprint.estimatedWorkingHeadroomBytes {
            throw HistoryFailure(.capacity, stage: .admission, disposition: .usable,
                                 underlyingDescription: "Insufficient filesystem space for a full store copy")
        }
        do { try context.save() }
        catch { context.rollback(); noteWriteFailure(); throw error }
        let coordinator = container.persistentStoreCoordinator
        let options: [AnyHashable: Any] = [NSSQLitePragmasOption: ["journal_mode": "DELETE"]]
        do {
            try coordinator.replacePersistentStore(at: destination, destinationOptions: options,
                                                   withPersistentStoreFrom: url, sourceOptions: nil,
                                                   ofType: NSSQLiteStoreType)
            let copied = NSPersistentStoreCoordinator(managedObjectModel: container.managedObjectModel)
            let snapshotStore = try copied.addPersistentStore(ofType: NSSQLiteStoreType,
                configurationName: nil, at: destination, options: options)
            try copied.remove(snapshotStore)
            guard !FileManager.default.fileExists(atPath: destination.path + "-wal") else {
                throw HistoryFailure(.storage, stage: .finalization, disposition: .usable)
            }
            let sharedMemory = URL(fileURLWithPath: destination.path + "-shm")
            if FileManager.default.fileExists(atPath: sharedMemory.path) {
                try FileManager.default.removeItem(at: sharedMemory)
            }
        } catch {
            // A failed destination is not offered as a coherent copy. The source
            // remains open, locked and available for inspection/recovery.
            try? FileManager.default.removeItem(at: destination)
            throw HistoryFailure(.storage, stage: .finalization, disposition: .usable,
                                 underlyingDescription: String(describing: error))
        }
    }

    /// Stops all scope admission, waits for delivered work, then releases the owner.
    public func close() async throws {
        guard !closed else { return }
        guard !maintenance else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        guard Self.deliveringStore != ObjectIdentifier(self) else {
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
