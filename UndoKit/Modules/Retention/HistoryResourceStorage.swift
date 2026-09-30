// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryEngine {
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
            let row = insert("HistoryResourceRecord")
            row.setValue(UUID().uuidString, forKey: "key")
            row.setValue(reference.storeID.uuidString, forKey: "storeID")
            row.setValue(reference.objectKey, forKey: "objectKey")
            row.setValue(reference.versionKey ?? "", forKey: "versionKey")
            row.setValue(ownerType, forKey: "ownerType")
            row.setValue(ownerKey, forKey: "ownerKey")
        }
    }

    func removeResourceReferences(ownerType: String, ownerKey: String) throws {
        let rows = try fetch("HistoryResourceRecord", predicate: NSPredicate(
            format: "ownerType == %@ AND ownerKey == %@", ownerType, ownerKey))
        for row in rows {
            if let storeID = row.string("storeID"),
               try fetchOne("HistoryCleanupRecord", key: storeID) == nil {
                let pending = insert("HistoryCleanupRecord")
                pending.setValue(storeID, forKey: "key")
            }
            context.delete(row)
        }
    }

    func retiredCommandReceipt(key: String, fingerprint: Data) throws -> HistoryReceipt? {
        guard let row = try fetchOne("HistoryRetiredCommandRecord", key: key) else { return nil }
        guard row.data("fingerprint") == fingerprint else {
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
        return HistoryReceipt(token: HistoryToken(scope: scope,
            generation: try row.uuid("generationID"), sequence: row.int64("sequence"),
            command: try row.uuid("commandID")), groupID: try row.uuid("groupID"))
    }
}
