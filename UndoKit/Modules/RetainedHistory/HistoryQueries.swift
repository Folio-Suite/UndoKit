// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension RetainedHistory {

    func createCheckpoint(
        id: UUID = UUID(), name: String?, state: HistoryPayload,
        resources: [HistoryObjectReference] = []
    ) throws -> HistoryCheckpointInfo {
        if store.writeFailed {
            throw HistoryFailure(.storage, stage: .admission, disposition: .suspended)
        }
        guard !activity.isExecuting, !activity.closed, !store.closing, !store.closed, !store.maintenance,
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

    func checkpoint(id: UUID) throws -> HistoryCheckpoint? {
        guard !activity.closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
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

    func checkpoints(after sequence: Int64? = nil, limit: Int) throws -> [HistoryCheckpointInfo] {
        guard !activity.closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
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

    func historyPage(after sequence: Int64? = nil, limit: Int) throws -> [HistoryEntry] {
        guard !activity.closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
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
}
