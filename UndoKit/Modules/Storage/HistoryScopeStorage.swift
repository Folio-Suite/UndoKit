// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

/// Scope-local persistence shared by transactions and retained-history operations.
/// Managed objects never cross the framework's public interface.
@MainActor final class HistoryScopeStorage {
    #if DEBUG
    enum FailurePoint: Sendable {
        case preparation, deliveryFence, acceptanceEvidence, rejectionEvidence
        case acceptedFinalization, rejectedFinalization, retention
    }
    @TaskLocal static var failSaveAt: FailurePoint?
    #endif
    let store: HistoryStore
    let scope: UUID
    let limits: HistoryLimits
    var url: URL { store.url }
    var context: NSManagedObjectContext { store.container.viewContext }

    init(store: HistoryStore, scope: UUID, limits: HistoryLimits) {
        self.store = store
        self.scope = scope
        self.limits = limits
    }

    func saveRetention() throws {
        do { try saveContext() } catch {
            context.rollback()
            throw HistoryFailure(.storage, stage: .finalization, disposition: .suspended,
                                 underlyingDescription: String(describing: error))
        }
    }

    // MainActor serializes context access, but a host callback can suspend a transaction.
    // Every protocol boundary saves before that suspension; rollback only affects unsaved
    // history changes and cannot retract a domain effect accepted in the host's own store.
    func saveContext() throws {
        do {
            #if DEBUG
            if shouldFailSave() { throw CocoaError(.fileWriteOutOfSpace) }
            #endif
            try context.save()
        } catch {
            context.rollback()
            store.noteWriteFailure()
            throw error
        }
    }

    #if DEBUG
    /// A stage-addressed test seam at the real context-save boundary, after
    /// admission/preflight. The normal rollback/write-failure path handles it.
    private func shouldFailSave() -> Bool {
        guard let point = Self.failSaveAt else { return false }
        if point == .retention { return context.hasChanges }
        let stage: String
        switch point {
        case .preparation: stage = "prepared"
        case .deliveryFence: stage = "deliveryStarted"
        case .acceptanceEvidence: stage = "acceptancePending"
        case .rejectionEvidence: stage = "rejectionPending"
        case .acceptedFinalization: stage = "accepted"
        case .rejectedFinalization: stage = "rejected"
        case .retention: return false
        }
        return context.insertedObjects.union(context.updatedObjects).contains { object in
            (object as? HistoryTransactionRecord)?.stage == stage
        }
    }
    #endif

    func register(mode: HistoryScopeOpenMode) throws {
        let key = scope.uuidString
        let row = try fetchOne(HistoryScopeRecord.self, keyPath: \.key, key: key)
        switch mode {
        case .create:
            guard row == nil else { throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable) }
            let new = insert(HistoryScopeRecord.self)
            new.key = key
            new.workingID = store.workingIdentity.uuidString
            new.generationID = UUID().uuidString
            new.nextSequence = Int64(1)
            new.suspended = false
            new.recordingEnabled = true
            new.undoFloorSequence = Int64(0)
            new.currentBaselineSequence = Int64(0)
            new.requiresGenerationBinding = false
            new.offStartSequence = Int64(0)
            try saveContext()
        case .existing:
            guard row?.workingID == store.workingIdentity.uuidString else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
        }
    }

    func eligibleGroup(for kind: HistoryDeliveryKind) throws -> HistoryGroupRecord? {
        let request = HistoryGroupRecord.fetchRequest()
        let floor = try scopeRecord().undoFloorSequence
        let groupFilter = "\(#keyPath(HistoryGroupRecord.scopeKey)) == %@ AND " +
            "\(#keyPath(HistoryGroupRecord.kind)) == %@ AND " +
            "\(#keyPath(HistoryGroupRecord.state)) != %@ AND " +
            "\(#keyPath(HistoryGroupRecord.sequence)) >= %@"
        request.predicate = NSPredicate(
            format: groupFilter,
            scope.uuidString, HistoryDeliveryKind.command.rawValue, "branched", NSNumber(value: floor))
        request.sortDescriptors = [NSSortDescriptor(key: #keyPath(HistoryGroupRecord.sequence), ascending: false)]
        request.fetchLimit = limits.maxUndoGroups
        let groups = try context.fetch(request)
        // An invalidated group blocks traversal until the host can prove a
        // narrower independent dependency scope. This first slice has no such proof.
        guard !groups.contains(where: { $0.state == "invalid" }) else { return nil }
        if kind == .undo { return groups.first(where: { $0.state == "applied" }) }
        return groups.reversed().first(where: { $0.state == "undone" })
    }

    func ordinaryGroups(state: String) throws -> [HistoryGroupRecord] {
        try fetch(HistoryGroupRecord.self,
                  predicate: NSPredicate(
                    format: "%K == %@ AND %K == %@ AND %K == %@",
                    #keyPath(HistoryGroupRecord.scopeKey), scope.uuidString,
                    #keyPath(HistoryGroupRecord.kind), HistoryDeliveryKind.command.rawValue,
                    #keyPath(HistoryGroupRecord.state), state),
                  sort: [NSSortDescriptor(key: #keyPath(HistoryGroupRecord.sequence), ascending: true)])
    }

    func valid(_ payload: HistoryPayload) -> Bool {
        !payload.family.isEmpty && payload.family.utf8.count <= 256 &&
            payload.version > 0 && payload.data.count <= limits.maxPayloadBytes
    }

    func valid(_ command: HistoryCommand) -> Bool {
        !command.fingerprint.isEmpty && command.fingerprint.count <= 4096 &&
            !command.members.isEmpty && command.members.count <= limits.maxMembers &&
            Set(command.members.map(\.id)).count == command.members.count &&
            command.members.allSatisfy { valid($0.payload) } &&
            command.presentation.map { valid($0) && $0.data.count <= 4_096 } != false &&
            command.members.reduce(0) { $0 + $1.payload.data.count } <= limits.maxPayloadBytes
    }

    func hasCapacity(for command: HistoryCommand) -> Bool {
        hasCapacity(bytes: command.members.reduce(0) { $0 + $1.payload.data.count }, reserveEffects: true)
    }

    func hasCapacity(bytes: Int, reserveEffects: Bool = false) -> Bool {
        let manager = FileManager.default
        let paths = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        let size = paths.reduce(Int64(0)) { sum, path in
            sum + Int64((try? manager.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let effectHeadroom = reserveEffects ? Int64(limits.maxPayloadBytes) * 4 : 0
        let estimate = Int64(bytes) * 2 + effectHeadroom + 1_048_576
        return size <= limits.maxStoreBytes && estimate <= limits.maxStoreBytes - size
    }

    func checkpointInfo(_ row: HistoryCheckpointRecord) throws -> HistoryCheckpointInfo {
        HistoryCheckpointInfo(id: try row.uuid(row.key), name: row.name,
                              sequence: row.sequence,
                              recordedAt: row.recordedAt ?? .distantPast)
    }

    func token(for transaction: HistoryTransactionRecord) throws -> HistoryToken {
        HistoryToken(scope: scope, generation: try transaction.uuid(transaction.generationID),
                     sequence: transaction.sequence, command: try transaction.uuid(transaction.commandID))
    }

    func transactionMembers(_ transaction: HistoryTransactionRecord) throws -> [HistoryMemberRecord] {
        let members = try fetch(HistoryMemberRecord.self,
                predicate: NSPredicate(format: "\(#keyPath(HistoryMemberRecord.transaction)) == %@", transaction),
                                sort: [NSSortDescriptor(key: #keyPath(HistoryMemberRecord.ordinal), ascending: true)])
        for row in members {
            guard let family = row.family,
                  let data = row.payload,
                  row.payloadDigest == digest(HistoryPayload(
                    family: family, version: Int(row.version), data: data
                  )) else {
                throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
            }
        }
        return members
    }

    func scopeRecord() throws -> HistoryScopeRecord {
        guard let row = try fetchOne(HistoryScopeRecord.self, keyPath: \.key, key: scope.uuidString) else {
            throw HistoryFailure(.compatibility, stage: .admission, disposition: .resetRequired)
        }
        return row
    }

    func groupRecord(key: String) throws -> HistoryGroupRecord? {
        try fetch(HistoryGroupRecord.self, predicate: NSPredicate(
            format: "%K == %@ AND %K == %@",
            #keyPath(HistoryGroupRecord.scopeKey), scope.uuidString,
            #keyPath(HistoryGroupRecord.key), key
        )).first
    }

    func transactionKey(_ id: UUID) -> String { scope.uuidString + ":" + id.uuidString }

    func insert<Record: HistoryManagedRecord>(_ type: Record.Type) -> Record {
        guard let name = type.fetchRequest().entityName,
              let entity = NSEntityDescription.entity(forEntityName: name, in: context) else {
            preconditionFailure("Missing UndoKit entity for \(type)")
        }
        return Record(entity: entity, insertInto: context)
    }

    func fetchOne<Record: HistoryManagedRecord>(
        _ type: Record.Type, keyPath: KeyPath<Record, String?>, key: String
    ) throws -> Record? {
        try fetch(type, predicate: NSPredicate(
            format: "%K == %@", NSExpression(forKeyPath: keyPath).keyPath, key
        )).first
    }

    func fetch<Record: HistoryManagedRecord>(
        _ type: Record.Type,
        predicate: NSPredicate? = nil,
        sort: [NSSortDescriptor] = []
    ) throws -> [Record] {
        let request = type.fetchRequest()
        request.fetchBatchSize = 256
        request.predicate = predicate
        request.sortDescriptors = sort
        return try context.fetch(request)
    }
}
