// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryEngine {

    /// Records host-confirmed coherent state. The host secures its required resources first.
    /// Checkpoint creation is synchronous and requires an idle, usable scope.
    public func createCheckpoint(
        id: UUID = UUID(), name: String?, state: HistoryPayload,
        resources: [HistoryObjectReference] = []
    ) throws -> HistoryCheckpointInfo {
        if store.writeFailed {
            throw HistoryFailure(.storage, stage: .admission, disposition: .suspended)
        }
        guard !transaction.isExecuting, !transaction.closed, !store.closing, !store.closed, !store.maintenance,
              !snapshot.isSuspended else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        guard history.valid(state), (name?.utf8.count ?? 0) <= 4096,
              history.valid(resources), history.hasCapacity(bytes: state.data.count) else {
            throw HistoryFailure(.capacity, stage: .admission, disposition: .usable)
        }
        guard try history.fetch("HistoryCheckpointRecord", predicate: NSPredicate(
            format: "scopeKey == %@ AND key == %@", scope.uuidString, id.uuidString
        )).isEmpty else {
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
        let scopeRow = try history.scopeRecord()
        let date = Date()
        let sequence = scopeRow.int64("nextSequence")
        let row = history.insert("HistoryCheckpointRecord")
        row.setValue(id.uuidString, forKey: "key")
        row.setValue(scope.uuidString, forKey: "scopeKey")
        row.setValue(name, forKey: "name")
        row.setValue(sequence, forKey: "sequence")
        row.setValue(scopeRow.int64("latestAcceptedSequence"), forKey: "latestAcceptedSequence")
        row.setValue(date, forKey: "recordedAt")
        row.setValue(state.family, forKey: "family")
        row.setValue(Int64(state.version), forKey: "version")
        row.setValue(state.data, forKey: "state")
        row.setValue(history.digest(state), forKey: "stateDigest")
        try history.addResourceReferences(resources, ownerType: "checkpoint",
                                  ownerKey: history.transactionKey(id))
        scopeRow.setValue(sequence + 1, forKey: "nextSequence")
        scopeRow.setValue(scopeRow.int64("committedVersion") + 1, forKey: "committedVersion")
        do {
            try history.saveContext()
        } catch {
            context.rollback()
            throw HistoryFailure(.storage, stage: .preparation, disposition: .usable)
        }
        return HistoryCheckpointInfo(id: id, name: name, sequence: sequence, recordedAt: date)
    }

    public func checkpoint(id: UUID) throws -> HistoryCheckpoint? {
        guard !transaction.closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        guard let row = try history.fetch("HistoryCheckpointRecord", predicate: NSPredicate(
            format: "scopeKey == %@ AND key == %@", scope.uuidString, id.uuidString
        )).first else { return nil }
        let state = HistoryPayload(family: row.string("family") ?? "",
                                   version: Int(row.int64("version")), data: row.data("state"))
        guard row.data("stateDigest") == history.digest(state) else {
            throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
        }
        return HistoryCheckpoint(info: try history.checkpointInfo(row), state: state)
    }

    /// Returns only metadata; state bytes require a separate checkpoint lookup.
    /// The page size cannot exceed the configured maximum.
    public func checkpoints(after sequence: Int64? = nil, limit: Int) throws -> [HistoryCheckpointInfo] {
        guard !transaction.closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        guard limit > 0, limit <= limits.maxReadPage else {
            throw HistoryFailure(.capacity, stage: .admission, disposition: .usable)
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryCheckpointRecord")
        request.predicate = NSPredicate(format: "scopeKey == %@ AND sequence > %@",
                                        scope.uuidString, NSNumber(value: sequence ?? 0))
        request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: true)]
        request.fetchLimit = limit
        return try context.fetch(request).map(history.checkpointInfo)
    }

    /// Returns committed structural history in bounded pages without decoding host payloads.
    public func historyPage(after sequence: Int64? = nil, limit: Int) throws -> [HistoryEntry] {
        guard !transaction.closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        guard limit > 0, limit <= limits.maxReadPage else {
            throw HistoryFailure(.capacity, stage: .admission, disposition: .usable)
        }
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

    /// Copies one idle and reconciled history store to a separate closed SQLite file.
    /// The host captures matching domain state and resources and registers the copy independently.
    public func copyStore(to destination: URL) throws {
        guard store.engines.count == 1 else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        try store.copyIdle(to: destination)
    }

    /// Stops admission, rejects queued requests and waits for active delivery.
    /// A convenience-opened session also closes its physical store.
    public func close() async throws {
        let wasClosed = transaction.closed
        try await transaction.close()
        if !wasClosed { store.engines.removeValue(forKey: scope) }
        if ownsConvenienceStore && !store.closed && (wasClosed || !store.closing) {
            try await store.close()
        }
    }
}
