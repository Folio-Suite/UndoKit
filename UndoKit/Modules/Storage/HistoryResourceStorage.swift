// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryScopeStorage {
    func valid(_ resources: [HistoryObjectReference]) -> Bool {
        resources.count <= 1_000 && Set(resources).count == resources.count &&
        resources.allSatisfy { reference in
            !reference.objectKey.isEmpty && reference.objectKey.utf8.count <= 512 &&
            !reference.objectKey.contains("\0") &&
            reference.versionKey?.isEmpty != true &&
            (reference.versionKey?.utf8.count ?? 0) <= 256 &&
            reference.versionKey?.contains("\0") != true
        }
    }

    func addResourceReferences(_ resources: [HistoryObjectReference],
                               ownerType: String, ownerKey: String) throws {
        for reference in resources {
            let row = insert(HistoryResourceRecord.self)
            row.key = UUID().uuidString
            row.storeID = reference.storeID.uuidString
            row.objectKey = reference.objectKey
            row.versionKey = reference.versionKey ?? ""
            row.ownerType = ownerType
            row.ownerKey = ownerKey
        }
    }

    func removeResourceReferences(ownerType: String, ownerKey: String) throws {
        let rows = try fetch(HistoryResourceRecord.self, predicate: NSPredicate(
            format: "\(#keyPath(HistoryResourceRecord.ownerType)) == %@ AND \(#keyPath(HistoryResourceRecord.ownerKey)) == %@", ownerType, ownerKey))
        for row in rows {
            if let storeID = row.storeID,
               try fetchOne(HistoryCleanupRecord.self, keyPath: \.key, key: storeID) == nil {
                let pending = insert(HistoryCleanupRecord.self)
                pending.key = storeID
            }
            context.delete(row)
        }
    }

    func retiredCommandReceipt(key: String, fingerprint: Data) throws -> HistoryReceipt? {
        guard let row = try fetchOne(HistoryRetiredCommandRecord.self, keyPath: \.key, key: key) else { return nil }
        guard row.fingerprint == fingerprint else {
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
        return HistoryReceipt(token: HistoryToken(scope: scope,
            generation: try row.uuid(row.generationID), sequence: row.sequence,
            command: try row.uuid(row.commandID)), groupID: try row.uuid(row.groupID))
    }
}
