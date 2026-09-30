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
            reference.versionKey != "" &&
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

extension HistoryStore {
    /// Distinct required objects are aggregated across all scopes. The caller
    /// pages by the last returned reference; each page is capped by maxReadPage.
    /// Ordering is lexicographic by canonical object key, then version key;
    /// an unversioned (`nil`) key sorts as the empty stored value. Pass the
    /// returned `nextCursor` to continue. An explicit empty version key is
    /// invalid on input, so cursors cannot conflate two object identities.
    /// Counts and pages are committed snapshots, not a stable sequence across
    /// concurrent writes. Use `withRequiredObjects(in:cleanup:)` for destructive
    /// host cleanup. Read-only sessions may call this method. A large required
    /// set needs multiple pages and a count query for each distinct object.
    public func requiredObjects(in retentionStore: UUID,
                                after cursor: HistoryObjectReference? = nil,
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
        request.sortDescriptors = [NSSortDescriptor(key: "objectKey", ascending: true),
                                   NSSortDescriptor(key: "versionKey", ascending: true)]
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

    /// Whether a prior pruning step removed references and host cleanup is due.
    public func cleanupPending(for retentionStore: UUID) throws -> Bool {
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryCleanupRecord")
        request.predicate = NSPredicate(format: "key == %@", retentionStore.uuidString)
        request.fetchLimit = 1
        return try !context.fetch(request).isEmpty
    }

    /// Fences admissions across all scopes while the host removes unrequired
    /// objects in its own atomic transaction. A failed callback leaves durable
    /// retry evidence, and the host can page required objects within the fence.
    /// The callback must perform its own durable cleanup; UndoKit never deletes
    /// host objects. It may read required-object pages but cannot re-enter
    /// history mutation or another maintenance operation on this store. This
    /// method waits for active deliveries, refuses unresolved transactions in
    /// any scope, and rejects read-only or failed writable sessions. Cancellation
    /// before the callback leaves the cleanup marker intact. Once the callback
    /// succeeds, cancellation cannot retract host cleanup; UndoKit clears the
    /// marker, or keeps it for retry if its own final save fails.
    public func withRequiredObjects(
        in retentionStore: UUID,
        cleanup: @MainActor (HistoryStore) async throws -> Void
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
        guard !Task.isCancelled else {
            throw HistoryFailure(.cancelled, stage: .admission, disposition: .usable)
        }
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
        do { try context.save() }
        catch {
            context.rollback()
            noteWriteFailure()
            throw HistoryFailure(.storage, stage: .finalization, disposition: .suspended)
        }
    }
}
