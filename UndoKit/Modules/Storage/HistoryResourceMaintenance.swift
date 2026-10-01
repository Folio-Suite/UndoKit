// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryStore {
    func requiredObjectsForRetention(in retentionStore: UUID,
                                     after cursor: HistoryObjectReference?,
                                     limit: Int) throws -> HistoryRequiredObjectPage {
        guard !closed, limit > 0, limit <= limits.maxReadPage,
              cursor?.versionKey?.isEmpty != true,
              cursor == nil || cursor?.storeID == retentionStore else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        let request = NSFetchRequest<NSDictionary>(entityName: "HistoryResourceRecord")
        var clauses = ["storeID == %@"]
        var values: [Any] = [retentionStore.uuidString]
        if let cursor {
            clauses.append("(objectKey > %@ OR (objectKey == %@ AND versionKey > %@))")
            values += [cursor.objectKey, cursor.objectKey, cursor.versionKey ?? ""]
        }
        request.predicate = NSPredicate(format: clauses.joined(separator: " AND "), argumentArray: values)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["objectKey", "versionKey"]
        request.returnsDistinctResults = true
        request.sortDescriptors = [
            NSSortDescriptor(key: "objectKey", ascending: true),
            NSSortDescriptor(key: "versionKey", ascending: true),
        ]
        request.fetchLimit = limit + 1
        let rows = try context.fetch(request)
        let pageRows = rows.prefix(limit)
        let objects = try pageRows.map { row -> HistoryRequiredObject in
            let objectKey = row["objectKey"] as? String ?? ""
            let versionKey = row["versionKey"] as? String ?? ""
            let count = try context.count(for: {
                let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "HistoryResourceRecord")
                countRequest.predicate = NSPredicate(
                    format: "storeID == %@ AND objectKey == %@ AND versionKey == %@",
                    retentionStore.uuidString, objectKey, versionKey)
                return countRequest
            }())
            return HistoryRequiredObject(reference: HistoryObjectReference(
                storeID: retentionStore, objectKey: objectKey,
                versionKey: versionKey.isEmpty ? nil : versionKey), referenceCount: count)
        }
        return HistoryRequiredObjectPage(objects: objects,
            nextCursor: rows.count > limit ? objects.last?.reference : nil)
    }

    func isRetentionCleanupPending(for retentionStore: UUID) throws -> Bool {
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryCleanupRecord")
        request.predicate = NSPredicate(format: "key == %@", retentionStore.uuidString)
        request.fetchLimit = 1
        return try !context.fetch(request).isEmpty
    }

    func performRequiredObjectCleanup(
        in retentionStore: UUID,
        cleanup: @MainActor (HistoryStore) async throws -> Void
    ) async throws {
        try await activity.withMaintenance(in: self) {
            let pending = NSFetchRequest<NSManagedObject>(entityName: "HistoryTransactionRecord")
            pending.predicate = NSPredicate(format: "stage != %@ AND stage != %@ AND stage != %@",
                                            "accepted", "rejected", "cancelled")
            pending.fetchLimit = 1
            guard try context.fetch(pending).isEmpty else {
                throw HistoryFailure(.unresolved, stage: .admission, disposition: .suspended)
            }
            try await cleanup(self)
            let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryCleanupRecord")
            request.predicate = NSPredicate(format: "key == %@", retentionStore.uuidString)
            for row in try context.fetch(request) { context.delete(row) }
            do { try context.save() } catch {
                context.rollback()
                noteWriteFailure()
                throw HistoryFailure(.storage, stage: .finalization, disposition: .suspended)
            }
        }
    }
}
