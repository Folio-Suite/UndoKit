// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryStore {
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
            _ = try copyScopes(boundTo: sourceWorkingIdentity, record: record)
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
            try createRegistration()
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
            guard let record else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
            let scopes = try copyScopes(boundTo: sourceWorkingIdentity, record: record)
            record.workingID = workingIdentity.uuidString
            record.storeID = storeIdentity.uuidString
            for scope in scopes { scope.workingID = workingIdentity.uuidString }
            do { try context.save() } catch { context.rollback(); throw error }
        }
    }

    private func copyScopes(boundTo sourceWorkingIdentity: UUID,
                            record: HistoryStoreRecord) throws -> [HistoryScopeRecord] {
        guard record.workingID == sourceWorkingIdentity.uuidString,
              sourceWorkingIdentity != workingIdentity else {
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
        let scopes = try context.fetch(HistoryScopeRecord.fetchRequest())
        guard scopes.allSatisfy({ $0.workingID == sourceWorkingIdentity.uuidString }) else {
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
        return scopes
    }

    private func createRegistration() throws {
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
    }
}
