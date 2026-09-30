// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import CryptoKit
import Foundation

extension HistoryEngine {
    func saveContext() throws {
        do { try context.save() } catch {
            context.rollback()
            store.noteWriteFailure()
            throw error
        }
    }

    func register(mode: HistoryScopeOpenMode) throws {
        let key = scope.uuidString
        let row = try fetchOne("HistoryScopeRecord", key: key)
        switch mode {
        case .create:
            guard row == nil else { throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable) }
            let new = insert("HistoryScopeRecord")
            new.setValue(key, forKey: "key")
            new.setValue(store.workingIdentity.uuidString, forKey: "workingID")
            new.setValue(UUID().uuidString, forKey: "generationID")
            new.setValue(Int64(1), forKey: "nextSequence")
            new.setValue(false, forKey: "suspended")
            try saveContext()
        case .existing:
            guard row?.string("workingID") == store.workingIdentity.uuidString else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
        }
    }

    func updateSnapshot() {
        if store.writeFailed {
            publishSnapshot(canUndo: false, canRedo: false, isSuspended: true,
                            hasPending: draining || !queue.isEmpty,
                            generation: snapshot.generation)
            return
        }
        guard !closed else {
            publishSnapshot(canUndo: false, canRedo: false,
                            isSuspended: snapshot.isSuspended, hasPending: false,
                            generation: snapshot.generation)
            return
        }
        do { try refreshSnapshot() } catch { suspend() }
    }

    func refreshSnapshot() throws {
        let row = try scopeRecord()
        let suspended = row.bool("suspended")
        let canUndo = try eligibleGroup(for: .undo) != nil
        let canRedo = try eligibleGroup(for: .redo) != nil
        publishSnapshot(canUndo: !suspended && !store.writeFailed && canUndo,
                        canRedo: !suspended && !store.writeFailed && canRedo,
                        isSuspended: suspended || store.writeFailed,
                        hasPending: draining || !queue.isEmpty,
                        generation: try row.uuid("generationID"))
    }

    func suspend() {
        context.rollback()
        if let row = try? scopeRecord() {
            row.setValue(true, forKey: "suspended")
            try? saveContext()
        }
        publishSnapshot(canUndo: false, canRedo: false, isSuspended: true,
                        hasPending: draining || !queue.isEmpty,
                        generation: (try? scopeRecord().uuid("generationID")) ?? snapshot.generation)
    }

    func unsuspend() {
        if let row = try? scopeRecord() {
            row.setValue(false, forKey: "suspended")
            try? saveContext()
        }
        updateSnapshot()
    }

    func publishSnapshot(canUndo: Bool, canRedo: Bool, isSuspended: Bool,
                         hasPending: Bool, generation: UUID?) {
        let candidate = HistorySnapshot(canUndo: canUndo, canRedo: canRedo,
                                        isSuspended: isSuspended, hasPending: hasPending,
                                        scope: scope, generation: generation, version: snapshot.version)
        guard candidate != snapshot else { return }
        let value = HistorySnapshot(canUndo: canUndo, canRedo: canRedo,
                                    isSuspended: isSuspended, hasPending: hasPending,
                                    scope: scope, generation: generation, version: snapshot.version + 1)
        snapshot = value
        snapshotDidChange?(value)
    }

    func eligibleGroup(for kind: HistoryDeliveryKind) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryGroupRecord")
        request.predicate = NSPredicate(format: "scopeKey == %@ AND kind == %@ AND state != %@",
                                        scope.uuidString, HistoryDeliveryKind.command.rawValue, "branched")
        request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: false)]
        request.fetchLimit = limits.maxUndoGroups
        let groups = try context.fetch(request)
        // An invalidated group blocks traversal until the host can prove a
        // narrower independent dependency scope. This first slice has no such proof.
        guard !groups.contains(where: { $0.string("state") == "invalid" }) else { return nil }
        if kind == .undo { return groups.first(where: { $0.string("state") == "applied" }) }
        return groups.reversed().first(where: { $0.string("state") == "undone" })
    }

    func ordinaryGroups(state: String) throws -> [NSManagedObject] {
        try fetch("HistoryGroupRecord",
                  predicate: NSPredicate(format: "scopeKey == %@ AND kind == %@ AND state == %@",
                                         scope.uuidString, HistoryDeliveryKind.command.rawValue, state),
                  sort: [NSSortDescriptor(key: "sequence", ascending: true)])
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

    func checkpointInfo(_ row: NSManagedObject) throws -> HistoryCheckpointInfo {
        HistoryCheckpointInfo(id: try row.uuid("key"), name: row.string("name"),
                              sequence: row.int64("sequence"),
                              recordedAt: row.value(forKey: "recordedAt") as? Date ?? .distantPast)
    }

    func token(for transaction: NSManagedObject) throws -> HistoryToken {
        HistoryToken(scope: scope, generation: try transaction.uuid("generationID"),
                     sequence: transaction.int64("sequence"), command: try transaction.uuid("commandID"))
    }

    func transactionMembers(_ transaction: NSManagedObject) throws -> [NSManagedObject] {
        let members = try fetch("HistoryMemberRecord",
                                predicate: NSPredicate(format: "transaction == %@", transaction),
                                sort: [NSSortDescriptor(key: "ordinal", ascending: true)])
        for row in members {
            guard let family = row.string("family"),
                  let data = row.value(forKey: "payload") as? Data,
                  row.data("payloadDigest") == digest(HistoryPayload(
                    family: family, version: Int(row.int64("version")), data: data
                  )) else {
                throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
            }
        }
        return members
    }

    func payload(on row: NSManagedObject, prefix: String) throws -> HistoryPayload {
        guard let family = row.string(prefix + "Family"),
              let data = row.value(forKey: prefix + "Payload") as? Data else {
            throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
        }
        let payload = HistoryPayload(family: family, version: Int(row.int64(prefix + "Version")), data: data)
        guard row.data(prefix + "Digest") == digest(payload) else {
            throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
        }
        return payload
    }

    func put(_ payload: HistoryPayload, on row: NSManagedObject, prefix: String) {
        row.setValue(payload.family, forKey: prefix + "Family")
        row.setValue(Int64(payload.version), forKey: prefix + "Version")
        row.setValue(payload.data, forKey: prefix + "Payload")
        row.setValue(digest(payload), forKey: prefix + "Digest")
    }

    func digest(_ payload: HistoryPayload) -> Data {
        var input = Data(payload.family.utf8)
        input.append(0)
        input.append(contentsOf: String(payload.version).utf8)
        input.append(0)
        input.append(payload.data)
        return Data(SHA256.hash(data: input))
    }

    func scopeRecord() throws -> NSManagedObject {
        guard let row = try fetchOne("HistoryScopeRecord", key: scope.uuidString) else {
            throw HistoryFailure(.compatibility, stage: .admission, disposition: .resetRequired)
        }
        return row
    }

    func groupRecord(key: String) throws -> NSManagedObject? {
        try fetch("HistoryGroupRecord", predicate: NSPredicate(
            format: "scopeKey == %@ AND key == %@", scope.uuidString, key
        )).first
    }

    func transactionKey(_ id: UUID) -> String { scope.uuidString + ":" + id.uuidString }

    func insert(_ name: String) -> NSManagedObject {
        NSEntityDescription.insertNewObject(forEntityName: name, into: context)
    }

    func fetchOne(_ name: String, key: String) throws -> NSManagedObject? {
        try fetch(name, predicate: NSPredicate(format: "key == %@", key)).first
    }

    func fetch(
        _ name: String,
        predicate: NSPredicate? = nil,
        sort: [NSSortDescriptor] = []
    ) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: name)
        request.predicate = predicate
        request.sortDescriptors = sort
        return try context.fetch(request)
    }
}

extension NSManagedObject {
    func string(_ key: String) -> String? { value(forKey: key) as? String }
    func data(_ key: String) -> Data { value(forKey: key) as? Data ?? Data() }
    func int64(_ key: String) -> Int64 { (value(forKey: key) as? NSNumber)?.int64Value ?? 0 }
    func bool(_ key: String) -> Bool { (value(forKey: key) as? NSNumber)?.boolValue ?? false }
    func uuid(_ key: String) throws -> UUID {
        guard let raw = string(key), let value = UUID(uuidString: raw) else {
            throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
        }
        return value
    }
}
