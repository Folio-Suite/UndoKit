// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Darwin
import Foundation

extension HistoryStore {
    #if DEBUG
    @TaskLocal static var failCopyAfterCreation = false
    #endif
    static func prepareOpening(at url: URL, mode: HistoryOpenMode, access: HistoryStoreAccess) throws {
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
    }

    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    static func storeArtifactURLs(at url: URL) -> [URL] {
        [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm"),
            URL(fileURLWithPath: url.path + "-journal"),
        ]
    }

    static func fileIdentity(at url: URL) throws -> FileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw HistoryFailure(.storage, stage: .admission, disposition: .suspended,
                                 underlyingDescription: "Cannot identify history artifact at \(url.path)")
        }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }

    static func removeCreatedArtifacts(at url: URL, preexisting: Set<URL>,
                                       expected: [URL: FileIdentity]? = nil) throws {
        let manager = FileManager.default
        let candidates = storeArtifactURLs(at: url).filter { !preexisting.contains($0) }
        let identities = try expected ?? Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            manager.fileExists(atPath: candidate.path)
                ? (candidate, try fileIdentity(at: candidate)) : nil
        })
        for candidate in candidates where manager.fileExists(atPath: candidate.path) {
            guard identities[candidate] == (try fileIdentity(at: candidate)) else {
                throw HistoryFailure(.storage, stage: .admission, disposition: .suspended,
                                     underlyingDescription: "History artifact changed: \(candidate.path)")
            }
        }
        for candidate in candidates.reversed() where manager.fileExists(atPath: candidate.path) {
            try manager.removeItem(at: candidate)
        }
    }

    func removeFailedCreationArtifacts(preexisting: Set<URL>) throws {
        let candidates = Self.storeArtifactURLs(at: url).filter { !preexisting.contains($0) }
        let identities = try Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            FileManager.default.fileExists(atPath: candidate.path)
                ? (candidate, try Self.fileIdentity(at: candidate)) : nil
        })
        context.rollback()
        let coordinator = container.persistentStoreCoordinator
        for persistentStore in coordinator.persistentStores { try coordinator.remove(persistentStore) }
        try Self.removeCreatedArtifacts(at: url, preexisting: preexisting, expected: identities)
    }

    struct OpeningArtifactStamp: Equatable {
        let device: UInt64
        let inode: UInt64
        let bytes: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    static func openingArtifactStamps(at url: URL) throws -> [String: OpeningArtifactStamp] {
        var stamps: [String: OpeningArtifactStamp] = [:]
        for suffix in ["", "-wal", "-journal"] {
            var info = stat()
            guard Darwin.lstat(url.path + suffix, &info) == 0 else {
                if errno == ENOENT { continue }
                throw HistoryFailure(.unavailableStore, stage: .admission, disposition: .usable)
            }
            stamps[suffix] = OpeningArtifactStamp(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                bytes: info.st_size, modifiedSeconds: info.st_mtimespec.tv_sec,
                modifiedNanoseconds: info.st_mtimespec.tv_nsec, changedSeconds: info.st_ctimespec.tv_sec,
                changedNanoseconds: info.st_ctimespec.tv_nsec)
        }
        return stamps
    }

    /// Copy data/journals, never shared-memory locks. MainActor excludes local
    /// saves during this synchronous capture; a writer's owner lock excludes
    /// other cooperating writers for writable preflight. A reader cannot take
    /// that lock from a live writer, so refuse if any source artifact changes
    /// identity, size, modification time or change time across the whole capture.
    /// Hosts still coordinate external movement/replacement of their files.
    static func makeOpeningSnapshot(at url: URL) throws -> URL {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("UndoKit-inspection-\(UUID())")
        do {
            let before = try openingArtifactStamps(at: url)
            guard before[""] != nil else {
                throw HistoryFailure(.missingHistory, stage: .admission, disposition: .usable)
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            let destination = directory.appendingPathComponent("History.sqlite")
            for suffix in ["", "-wal", "-journal"] where before[suffix] != nil {
                try manager.copyItem(at: URL(fileURLWithPath: url.path + suffix),
                                     to: URL(fileURLWithPath: destination.path + suffix))
            }
            guard before == (try openingArtifactStamps(at: url)) else {
                throw HistoryFailure(.busy, stage: .admission, disposition: .usable,
                                     underlyingDescription: "History changed during inspection capture; retry opening")
            }
            return directory
        } catch {
            try? manager.removeItem(at: directory)
            if let failure = error as? HistoryFailure { throw failure }
            throw HistoryFailure(.unavailableStore, stage: .admission, disposition: .usable,
                                 underlyingDescription: String(describing: error))
        }
    }

    static func makeValidatedInspection(at url: URL, workingIdentity: UUID, mode: HistoryOpenMode,
                                        limits: HistoryLimits) async throws -> HistoryStore {
        let directory = try makeOpeningSnapshot(at: url)
        do {
            let container = try makeContainer(at: directory.appendingPathComponent("History.sqlite"), readOnly: true)
            let inspection = HistoryStore(url: url, workingIdentity: workingIdentity,
                storeIdentity: UUID(), access: .readOnly, limits: limits,
                container: container, lockDescriptor: -1)
            inspection.inspectionDirectory = directory
            do { try inspection.validateRegistration(mode: mode) } catch {
                try await inspection.close()
                throw error
            }
            return inspection
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func safePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".." &&
        !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    static func valid(_ limits: HistoryLimits) -> Bool {
        limits.maxPayloadBytes > 0 && limits.maxPayloadBytes <= 64 * 1024 * 1024 &&
        limits.maxMembers > 0 && limits.maxMembers <= 1_000 &&
        limits.maxQueueDepth > 0 && limits.maxQueueDepth <= 1_024 &&
        limits.maxStoreBytes > 0 && limits.maxStoreBytes <= 4 * 1024 * 1024 * 1024 * 1024 &&
        limits.maxUndoGroups > 0 && limits.maxUndoGroups <= 100_000 &&
        limits.maxReadPage > 0 && limits.maxReadPage <= 1_000 &&
        limits.maxRecoveryPlans > 0 && limits.maxRecoveryPlans <= 1_024
    }

    static func makeContainer(at url: URL, readOnly: Bool) throws -> NSPersistentContainer {
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
        // Store loading must complete before register(mode:) inspects durable identity.
        // The local loadError below relies on synchronous store addition; async public
        // opening does not make this Core Data configuration callback asynchronous.
        // https://developer.apple.com/documentation/coredata/nspersistentstoredescription/shouldaddstoreasynchronously
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = false
        description.shouldInferMappingModelAutomatically = false
        if readOnly { description.setOption(true as NSNumber, forKey: NSReadOnlyPersistentStoreOption) }
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            for persistentStore in container.persistentStoreCoordinator.persistentStores {
                do { try container.persistentStoreCoordinator.remove(persistentStore) } catch {
                    throw HistoryFailure(.storage, stage: .admission, disposition: .suspended,
                        underlyingDescription: "Could not close failed store before cleanup: \(error)")
                }
            }
            throw HistoryFailure(openCause(for: loadError), stage: .admission, disposition: .usable,
                                 underlyingDescription: String(describing: loadError))
        }
        return container
    }

    static func openCause(for error: Error) -> HistoryFailureCause {
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

    /// Establish compatibility and binding before any writable coordinator touches
    /// the original. This method never edits records, including copy adoption.
    func validateRegistration(mode: HistoryOpenMode) throws {
        let request = HistoryStoreRecord.fetchRequest()
        request.predicate = NSPredicate(format: "\(#keyPath(HistoryStoreRecord.key)) == %@", "primary")
        request.fetchLimit = 2
        let records = try context.fetch(request)
        guard records.count == 1, let record = records.first,
              let storeID = record.storeID.flatMap(UUID.init(uuidString:)),
              record.workingID.flatMap(UUID.init(uuidString:)) != nil else {
            throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
        }
        switch mode {
        case .create:
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        case .existing:
            guard record.workingID == workingIdentity.uuidString else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
            storeIdentity = storeID
        case .independentCopy(let sourceWorkingIdentity):
            guard record.workingID == sourceWorkingIdentity.uuidString,
                  sourceWorkingIdentity != workingIdentity else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
            let scopes = try context.fetch(HistoryScopeRecord.fetchRequest())
            guard scopes.allSatisfy({ $0.workingID == sourceWorkingIdentity.uuidString }) else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
        }
    }

    func register(mode: HistoryOpenMode) throws {
        let request = HistoryStoreRecord.fetchRequest()
        request.predicate = NSPredicate(format: "\(#keyPath(HistoryStoreRecord.key)) == %@", "primary")
        request.fetchLimit = 1
        let record = try context.fetch(request).first
        switch mode {
        case .create:
            guard record == nil else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
            guard let name = HistoryStoreRecord.fetchRequest().entityName,
                  let created = NSEntityDescription.insertNewObject(
                forEntityName: name, into: context
            ) as? HistoryStoreRecord else {
                throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
            }
            created.key = "primary"
            created.workingID = workingIdentity.uuidString
            created.storeID = storeIdentity.uuidString
            do {
                #if DEBUG
                if Self.failInitialRegistrationSave {
                    throw HistoryFailure(.storage, stage: .admission, disposition: .usable,
                        underlyingDescription: "Injected first registration save failure")
                }
                #endif
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        case .existing:
            guard let record else {
                throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
            }
            guard record.workingID == workingIdentity.uuidString,
                  let storeID = record.storeID.flatMap(UUID.init(uuidString:)) else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
            storeIdentity = storeID
        case .independentCopy(let sourceWorkingIdentity):
            guard let record, record.workingID == sourceWorkingIdentity.uuidString,
                  sourceWorkingIdentity != workingIdentity else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
            let scopes = try context.fetch(HistoryScopeRecord.fetchRequest())
            guard scopes.allSatisfy({ $0.workingID == sourceWorkingIdentity.uuidString }) else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
            record.workingID = workingIdentity.uuidString
            record.storeID = storeIdentity.uuidString
            for scope in scopes { scope.workingID = workingIdentity.uuidString }
            do { try context.save() } catch { context.rollback(); throw error }
        }
    }

    func copyIdle(to destination: URL, allowingUnresolved: Bool = false) throws {
        guard access == .readWrite, !closed, !closing,
              engines.values.allSatisfy({ engine in
                  !engine.transaction.isActive &&
                  (allowingUnresolved || !engine.snapshot.isSuspended)
              }) else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        guard Self.storeArtifactURLs(at: destination).allSatisfy({
            !FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
        let pending = HistoryTransactionRecord.fetchRequest()
        pending.predicate = NSPredicate(format: "\(#keyPath(HistoryTransactionRecord.stage)) != %@ AND " +
            "\(#keyPath(HistoryTransactionRecord.stage)) != %@ AND " +
            "\(#keyPath(HistoryTransactionRecord.stage)) != %@",
                                        "accepted", "rejected", "cancelled")
        pending.fetchLimit = 1
        guard try allowingUnresolved || context.fetch(pending).isEmpty else {
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
        do { try context.save() } catch {
            context.rollback()
            noteWriteFailure()
            throw error
        }
        do {
            try createClosedCopy(at: destination)
        } catch {
            // Never offer an incomplete destination. Preserve the live source and
            // remove every owned destination artifact, including SQLite journals.
            do { try Self.removeCreatedArtifacts(at: destination, preexisting: []) } catch let cleanupError {
                throw HistoryFailure(.storage, stage: .finalization, disposition: .usable,
                    underlyingDescription: "Copy failed: \(error). Destination cleanup failed: \(cleanupError)")
            }
            throw HistoryFailure(.storage, stage: .finalization, disposition: .usable,
                                 underlyingDescription: String(describing: error))
        }
    }

    private func createClosedCopy(at destination: URL) throws {
        let options: [AnyHashable: Any] = [NSSQLitePragmasOption: ["journal_mode": "DELETE"]]
        // Copy through Core Data: committed pages may still live in the WAL.
        try container.persistentStoreCoordinator.replacePersistentStore(at: destination,
            destinationOptions: options, withPersistentStoreFrom: url,
            sourceOptions: nil, ofType: NSSQLiteStoreType)
        #if DEBUG
        if Self.failCopyAfterCreation { throw CocoaError(.fileWriteOutOfSpace) }
        #endif
        let copied = NSPersistentStoreCoordinator(managedObjectModel: container.managedObjectModel)
        do {
            let snapshotStore = try copied.addPersistentStore(ofType: NSSQLiteStoreType,
                configurationName: nil, at: destination, options: options)
            try copied.remove(snapshotStore)
        } catch {
            for store in copied.persistentStores { try copied.remove(store) }
            throw error
        }
        guard !FileManager.default.fileExists(atPath: destination.path + "-wal") else {
            throw HistoryFailure(.storage, stage: .finalization, disposition: .usable)
        }
        let sharedMemory = URL(fileURLWithPath: destination.path + "-shm")
        if FileManager.default.fileExists(atPath: sharedMemory.path) {
            try FileManager.default.removeItem(at: sharedMemory)
        }
    }

}
