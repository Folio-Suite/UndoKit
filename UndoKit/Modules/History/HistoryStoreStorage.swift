// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryStore {
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
        limits.maxReadPage > 0 && limits.maxReadPage <= 1_000
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

    func register(mode: HistoryOpenMode) throws {
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

    func copyIdle(to destination: URL) throws {
        guard access == .readWrite, !closed, !closing,
              engines.values.allSatisfy({ engine in
                  !engine.draining && engine.queue.isEmpty && !engine.reconciling && !engine.snapshot.isSuspended
              }) else {
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
        do { try context.save() } catch {
            context.rollback()
            noteWriteFailure()
            throw error
        }
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

}
