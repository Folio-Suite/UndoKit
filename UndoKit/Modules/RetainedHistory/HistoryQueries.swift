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
        guard try history.fetch(HistoryCheckpointRecord.self, predicate: NSPredicate(
            format: "\(#keyPath(HistoryCheckpointRecord.scopeKey)) == %@ AND \(#keyPath(HistoryCheckpointRecord.key)) == %@", scope.uuidString, id.uuidString
        )).isEmpty else {
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
        let scopeRow = try history.scopeRecord()
        let date = Date()
        let sequence = scopeRow.nextSequence
        let row = history.insert(HistoryCheckpointRecord.self)
        row.key = id.uuidString
        row.scopeKey = scope.uuidString
        row.name = name
        row.sequence = sequence
        row.latestAcceptedSequence = scopeRow.latestAcceptedSequence
        row.recordedAt = date
        row.family = state.family
        row.version = Int64(state.version)
        row.state = state.data
        row.stateDigest = history.digest(state)
        try history.addResourceReferences(resources, ownerType: "checkpoint",
                                  ownerKey: history.transactionKey(id))
        scopeRow.nextSequence = sequence + 1
        scopeRow.committedVersion += 1
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
        guard let row = try history.fetch(HistoryCheckpointRecord.self, predicate: NSPredicate(
            format: "\(#keyPath(HistoryCheckpointRecord.scopeKey)) == %@ AND \(#keyPath(HistoryCheckpointRecord.key)) == %@", scope.uuidString, id.uuidString
        )).first else { return nil }
        let state = HistoryPayload(family: row.family ?? "",
                                   version: Int(row.version), data: row.state ?? Data())
        guard row.stateDigest == history.digest(state) else {
            throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
        }
        return HistoryCheckpoint(info: try history.checkpointInfo(row), state: state)
    }

    func checkpoints(after sequence: Int64? = nil, limit: Int) throws -> [HistoryCheckpointInfo] {
        guard !activity.closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        guard limit > 0, limit <= limits.maxReadPage else {
            throw HistoryFailure(.capacity, stage: .admission, disposition: .usable)
        }
        let request = NSFetchRequest<HistoryCheckpointRecord>(entityName: "HistoryCheckpointRecord")
        request.predicate = NSPredicate(format: "\(#keyPath(HistoryCheckpointRecord.scopeKey)) == %@ AND \(#keyPath(HistoryCheckpointRecord.sequence)) > %@",
                                        scope.uuidString, NSNumber(value: sequence ?? 0))
        request.sortDescriptors = [NSSortDescriptor(key: #keyPath(HistoryCheckpointRecord.sequence), ascending: true)]
        request.fetchLimit = limit
        return try context.fetch(request).map(history.checkpointInfo)
    }

    func historyPage(after sequence: Int64? = nil, limit: Int) throws -> [HistoryEntry] {
        guard !activity.closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        guard limit > 0, limit <= limits.maxReadPage else {
            throw HistoryFailure(.capacity, stage: .admission, disposition: .usable)
        }
        let request = NSFetchRequest<HistoryGroupRecord>(entityName: "HistoryGroupRecord")
        request.predicate = NSPredicate(format: "\(#keyPath(HistoryGroupRecord.scopeKey)) == %@ AND \(#keyPath(HistoryGroupRecord.sequence)) > %@",
                                        scope.uuidString, NSNumber(value: sequence ?? 0))
        request.sortDescriptors = [NSSortDescriptor(key: #keyPath(HistoryGroupRecord.sequence), ascending: true)]
        request.fetchLimit = limit
        return try context.fetch(request).map { row in
            HistoryEntry(groupID: try row.uuid(row.key), sequence: row.sequence,
                         kind: HistoryEntryKind(rawValue: row.kind ?? "") ?? .command,
                         sourceGroupID: row.sourceGroupID.flatMap(UUID.init(uuidString:)),
                         compensationGroupID: row.compensationGroupID.flatMap(UUID.init(uuidString:)),
                         restorationOrigin: row.restorationOrigin.flatMap(UUID.init(uuidString:)),
                         memberCount: Int(row.memberCount),
                         recordedAt: row.recordedAt ?? .distantPast)
        }
    }
}
