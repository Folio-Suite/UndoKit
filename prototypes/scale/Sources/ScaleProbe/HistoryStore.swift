// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import CoreData
import Foundation

public struct Effect: Sendable {
    public let key: String
    public let value: Data?
    public let command: Data
    public init(key: String, value: Data?, command: Data) {
        self.key = key; self.value = value; self.command = command
    }
    public static func set(_ key: String, _ value: String) -> Self {
        Self(key: key, value: Data(value.utf8), command: Data(("set:" + key).utf8))
    }
}
public struct Resource: Hashable, Sendable {
    public let store: String
    public let key: String
    public let version: String
    public init(store: String, key: String, version: String) {
        self.store = store; self.key = key; self.version = version
    }
}
public struct Limits: Sendable {
    public var maxPayload = 32 * 1_024 * 1_024
    public var maxGroupBytes = 64 * 1_024 * 1_024
    public var maxActions = 4_096
    public var maxReferences = 65_536
    public var hardStoreBytes: Int64?
    public var pageEntries = 256
    public var pageBytes = 16 * 1_024 * 1_024
    public init() {}
}
public enum ProofError: Error, Equatable {
    case refused(String), missing(String), gap(String), noUndo, noRedo
}
public struct NodeInfo: Sendable {
    public let id: String
    public let parent: String?
    public let origin: String?
    public let kind: String
    public let gapBefore: Bool
}
public struct RecoveryResult: Sendable {
    public let state: [String: String]
    public let recordsVisited: Int
    public let bytesRead: Int
    public let baseline: String?
}
public struct PlanPage: Sendable {
    public let nodeIDs: [String]
    public let bytesRead: Int
    public let advertisedBytes: Int
    public let hasMore: Bool
}
@MainActor public final class HistoryStore {
    public let url: URL
    public var limits: Limits
    private let container: NSPersistentContainer
    private var context: NSManagedObjectContext { container.viewContext }
    public static func temporary(limits: Limits = Limits()) throws -> HistoryStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScaleProbe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try Self(url: folder.appendingPathComponent("History.sqlite"), limits: limits)
    }
    public init(url: URL, limits: Limits = Limits()) throws {
        self.url = url; self.limits = limits
        container = NSPersistentContainer(name: "ScaleProof", managedObjectModel: Self.model())
        let description = NSPersistentStoreDescription(url: url)
        description.type = NSSQLiteStoreType
        description.setOption(["journal_mode": "WAL"] as NSDictionary, forKey: NSSQLitePragmasOption)
        container.persistentStoreDescriptions = [description]
        var openingError: Error?
        container.loadPersistentStores { _, error in openingError = error }
        if let openingError { throw openingError }
        context.undoManager = nil
        // Recovery plans are session-bound. An interrupted process cannot hold
        // historical material forever after the store is reopened.
        for plan in try fetch("Plan") { context.delete(plan) }
        if context.hasChanges { try context.save() }
    }
    public func close() throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
    private static func model() -> NSManagedObjectModel {
        func attr(_ name: String, _ type: NSAttributeType, _ optional: Bool = false) -> NSAttributeDescription {
            let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = optional
            return a
        }
        func entity(_ name: String, _ fields: [NSAttributeDescription], unique: [[String]] = []) -> NSEntityDescription {
            let e = NSEntityDescription(); e.name = name; e.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
            e.properties = fields; e.uniquenessConstraints = unique
            return e
        }
        let model = NSManagedObjectModel()
        model.entities = [
            entity("Scope", [attr("id", .stringAttributeType), attr("head", .stringAttributeType, true), attr("redo", .stringAttributeType, true), attr("sequence", .integer64AttributeType), attr("redoOrdinal", .integer64AttributeType), attr("undoDepth", .integer32AttributeType, true), attr("undoFloor", .stringAttributeType, true), attr("floorCheckpoint", .stringAttributeType, true)], unique: [["id"]]),
            entity("Node", [attr("id", .stringAttributeType), attr("scope", .stringAttributeType), attr("parent", .stringAttributeType, true), attr("origin", .stringAttributeType, true), attr("kind", .stringAttributeType), attr("sequence", .integer64AttributeType), attr("gapBefore", .booleanAttributeType)], unique: [["id"]]),
            entity("Effect", [attr("id", .stringAttributeType), attr("node", .stringAttributeType), attr("ordinal", .integer32AttributeType), attr("key", .stringAttributeType), attr("value", .binaryDataAttributeType, true), attr("command", .binaryDataAttributeType), attr("valueBytes", .integer64AttributeType), attr("commandBytes", .integer64AttributeType)], unique: [["id"]]),
            entity("Checkpoint", [attr("id", .stringAttributeType), attr("node", .stringAttributeType), attr("scope", .stringAttributeType), attr("snapshot", .binaryDataAttributeType)], unique: [["id"]]),
            entity("Hold", [attr("id", .stringAttributeType), attr("node", .stringAttributeType), attr("kind", .stringAttributeType), attr("until", .stringAttributeType, true), attr("checkpointID", .stringAttributeType, true)], unique: [["id"]]),
            entity("Reference", [attr("id", .stringAttributeType), attr("owner", .stringAttributeType), attr("store", .stringAttributeType), attr("key", .stringAttributeType), attr("version", .stringAttributeType)], unique: [["id"]]),
            entity("Plan", [attr("id", .stringAttributeType), attr("target", .stringAttributeType), attr("scope", .stringAttributeType)], unique: [["id"]]),
            entity("Redo", [attr("id", .stringAttributeType), attr("scope", .stringAttributeType), attr("node", .stringAttributeType), attr("ordinal", .integer64AttributeType)], unique: [["id"]])
        ]
        return model
    }
    private func fetch(_ entity: String, _ predicate: NSPredicate? = nil, limit: Int = 0, sort: [NSSortDescriptor] = []) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = predicate; request.fetchLimit = limit; request.fetchBatchSize = 256; request.sortDescriptors = sort
        return try context.fetch(request)
    }
    private func one(_ entity: String, _ key: String, _ value: String) throws -> NSManagedObject? {
        try fetch(entity, NSPredicate(format: "%K == %@", key, value), limit: 1).first
    }
    private func put(_ entity: String) -> NSManagedObject {
        NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
    }
    private func str(_ row: NSManagedObject, _ field: String) -> String? { row.value(forKey: field) as? String }
    private func scope(_ id: String) throws -> NSManagedObject {
        if let row = try one("Scope", "id", id) { return row }
        let row = put("Scope"); row.setValue(id, forKey: "id"); row.setValue(Int64(0), forKey: "sequence"); row.setValue(Int64(0), forKey: "redoOrdinal")
        return row
    }
    public func node(_ id: String) throws -> NodeInfo? {
        guard let row = try one("Node", "id", id) else { return nil }
        return NodeInfo(id: id, parent: str(row, "parent"), origin: str(row, "origin"),
                        kind: str(row, "kind")!, gapBefore: row.value(forKey: "gapBefore") as? Bool ?? false)
    }
    public func head(scope id: String) throws -> String? { str(try scope(id), "head") }
    public func append(scope id: String, actions: [Effect], resources: [Resource] = [],
                       kind: String = "edit", origin: String? = nil, nodeID: String? = nil, durable: Bool = true) throws -> String {
        guard !actions.isEmpty, actions.count <= limits.maxActions else { throw ProofError.refused("action count") }
        guard resources.count <= limits.maxReferences else { throw ProofError.refused("reference count") }
        var size = 0
        for action in actions {
            guard action.command.count <= limits.maxPayload, (action.value?.count ?? 0) <= limits.maxPayload else {
                throw ProofError.refused("payload bytes")
            }
            size += action.command.count + (action.value?.count ?? 0)
            guard size <= limits.maxGroupBytes else { throw ProofError.refused("group bytes") }
        }
        let conservativeGrowth = Int64(size) * 2 + 1_024 * 1_024
        if let hard = limits.hardStoreBytes, try fileFootprint() + conservativeGrowth > hard {
            throw ProofError.refused("store capacity")
        }
        let owner = try scope(id)
        let parent = str(owner, "head")
        let sequence = (owner.value(forKey: "sequence") as? Int64 ?? 0) + 1
        let idNew = nodeID ?? UUID().uuidString
        let group = put("Node")
        group.setValue(idNew, forKey: "id"); group.setValue(id, forKey: "scope")
        group.setValue(parent, forKey: "parent"); group.setValue(origin, forKey: "origin")
        group.setValue(kind, forKey: "kind"); group.setValue(sequence, forKey: "sequence")
        group.setValue(false, forKey: "gapBefore")
        for (ordinal, action) in actions.enumerated() {
            let row = put("Effect")
            row.setValue(UUID().uuidString, forKey: "id"); row.setValue(idNew, forKey: "node")
            row.setValue(Int32(ordinal), forKey: "ordinal"); row.setValue(action.key, forKey: "key")
            row.setValue(action.value, forKey: "value"); row.setValue(action.command, forKey: "command")
            row.setValue(Int64(action.value?.count ?? 0), forKey: "valueBytes")
            row.setValue(Int64(action.command.count), forKey: "commandBytes")
        }
        for resource in resources { putReference(owner: idNew, resource: resource) }
        for redo in try fetch("Redo", NSPredicate(format: "scope == %@", id)) { context.delete(redo) }
        owner.setValue(idNew, forKey: "head"); owner.setValue(nil, forKey: "redo")
        owner.setValue(sequence, forKey: "sequence")
        if owner.value(forKey: "undoDepth") != nil { try updateUndoFloor(owner) }
        if durable { try flush() }
        return idNew
    }
    public func flush() throws {
        if context.hasChanges { try context.save() }
        context.reset()
    }
    private func putReference(owner: String, resource: Resource) {
        let row = put("Reference")
        row.setValue(UUID().uuidString, forKey: "id"); row.setValue(owner, forKey: "owner")
        row.setValue(resource.store, forKey: "store"); row.setValue(resource.key, forKey: "key")
        row.setValue(resource.version, forKey: "version")
    }
    public func configureUndoDepth(scope id: String, groups: Int) throws {
        guard groups >= 0 && groups <= Int(Int32.max) else { throw ProofError.refused("undo depth") }
        let owner = try scope(id)
        owner.setValue(Int32(groups), forKey: "undoDepth")
        try updateUndoFloor(owner)
        try flush()
    }
    private func updateUndoFloor(_ owner: NSManagedObject) throws {
        guard let depth = owner.value(forKey: "undoDepth") as? Int32 else { return }
        let previousFloor = str(owner, "undoFloor")
        let previousCheckpoint = str(owner, "floorCheckpoint")
        var cursor = str(owner, "head")
        for _ in 0..<depth {
            guard let current = cursor, let parent = try node(current)?.parent else { break }
            cursor = parent
        }
        if cursor == previousFloor { return }
        var nextCheckpoint: String?
        if let cursor, try checkpoint(node: cursor) == nil {
            nextCheckpoint = try checkpoint(scope: str(owner, "id")!, node: cursor)
        }
        if let previousCheckpoint, let old = try one("Checkpoint", "id", previousCheckpoint) {
            for ref in try fetch("Reference", NSPredicate(format: "owner == %@", previousCheckpoint)) {
                context.delete(ref)
            }
            context.delete(old)
        }
        owner.setValue(cursor, forKey: "undoFloor")
        owner.setValue(nextCheckpoint, forKey: "floorCheckpoint")
    }
    public func undo(scope id: String) throws {
        let owner = try scope(id)
        guard let current = str(owner, "head"), current != str(owner, "undoFloor"),
              let info = try node(current),
              !info.gapBefore, let parent = info.parent,
              try node(parent) != nil else { throw ProofError.noUndo }
        let ordinal = (owner.value(forKey: "redoOrdinal") as? Int64 ?? 0) + 1
        let redo = put("Redo")
        redo.setValue(UUID().uuidString, forKey: "id"); redo.setValue(id, forKey: "scope")
        redo.setValue(current, forKey: "node"); redo.setValue(ordinal, forKey: "ordinal")
        owner.setValue(parent, forKey: "head"); owner.setValue(ordinal, forKey: "redoOrdinal")
        try flush()
    }
    public func redo(scope id: String) throws {
        let owner = try scope(id)
        guard let row = try fetch("Redo", NSPredicate(format: "scope == %@", id), limit: 1,
                                  sort: [NSSortDescriptor(key: "ordinal", ascending: false)]).first,
              let target = str(row, "node") else { throw ProofError.noRedo }
        context.delete(row)
        owner.setValue(target, forKey: "head")
        try flush()
    }
    public func restore(scope id: String, target: String) throws -> String {
        let state = try reconstruct(scope: id, node: target).state
        let data = try JSONEncoder().encode(state)
        return try append(scope: id, actions: [Effect(key: "*", value: data,
                    command: Data(("restore:" + target).utf8))], kind: "restore", origin: target)
    }
    public func recoverSelected(scope id: String, target: String, keys: [String]) throws -> String {
        let state = try reconstruct(scope: id, node: target).state
        let actions = keys.sorted().map { key -> Effect in
            if let value = state[key] { return .set(key, value) }
            return Effect(key: key, value: nil, command: Data(("recover:" + key).utf8))
        }
        return try append(scope: id, actions: actions, kind: "selected", origin: target)
    }
    public func currentState(scope id: String) throws -> [String: String] {
        guard let target = try head(scope: id) else { return [:] }
        return try reconstruct(scope: id, node: target).state
    }
    public func checkpoint(scope id: String, node target: String, resources: [Resource] = []) throws -> String {
        let snapshot = try JSONEncoder().encode(reconstruct(scope: id, node: target).state)
        let (lineage, baseline) = try path(to: target)
        let checkpointID = UUID().uuidString
        let row = put("Checkpoint")
        row.setValue(checkpointID, forKey: "id"); row.setValue(target, forKey: "node")
        row.setValue(id, forKey: "scope"); row.setValue(snapshot, forKey: "snapshot")
        // This prototype lacks a host dependency oracle. Copying the lineage's
        // references conservatively prevents a held snapshot from losing an
        // ancestor-only resource; it may retain resources that state no longer uses.
        var owners = lineage
        if let baselineID = baseline.flatMap({ str($0, "id") }) { owners.append(baselineID) }
        var required = Set(resources)
        for start in stride(from: 0, to: owners.count, by: 256) {
            let batch = Array(owners[start..<min(owners.count, start + 256)])
            for ref in try fetch("Reference", NSPredicate(format: "owner IN %@", batch)) {
                required.insert(Resource(store: str(ref, "store")!, key: str(ref, "key")!,
                                         version: str(ref, "version")!))
            }
        }
        for resource in required { putReference(owner: checkpointID, resource: resource) }
        try context.save()
        return checkpointID
    }
    public func hold(node target: String, kind: String, until: String? = nil) throws -> String {
        guard kind == "state" || kind == "history" else { throw ProofError.refused("hold kind") }
        guard let nodeRow = try one("Node", "id", target) else { throw ProofError.missing(target) }
        let idNew = UUID().uuidString
        let row = put("Hold")
        row.setValue(idNew, forKey: "id"); row.setValue(target, forKey: "node")
        row.setValue(kind, forKey: "kind"); row.setValue(until, forKey: "until")
        if kind == "state" {
            let checkpointID = try checkpoint(scope: str(nodeRow, "scope")!, node: target)
            row.setValue(checkpointID, forKey: "checkpointID")
        }
        try context.save(); return idNew
    }
    public func releaseHold(_ id: String) throws {
        guard let row = try one("Hold", "id", id) else { throw ProofError.missing(id) }
        if let checkpointID = str(row, "checkpointID"),
           let checkpointRow = try one("Checkpoint", "id", checkpointID) {
            for ref in try fetch("Reference", NSPredicate(format: "owner == %@", checkpointID)) {
                context.delete(ref)
            }
            context.delete(checkpointRow)
        }
        context.delete(row); try context.save()
    }
    public func beginPlan(scope id: String, target: String) throws -> String {
        guard let row = try one("Node", "id", target), str(row, "scope") == id else { throw ProofError.missing(target) }
        let planID = UUID().uuidString
        let plan = put("Plan"); plan.setValue(planID, forKey: "id")
        plan.setValue(id, forKey: "scope"); plan.setValue(target, forKey: "target")
        try context.save(); return planID
    }
    public func releasePlan(_ id: String) throws {
        guard let row = try one("Plan", "id", id) else { throw ProofError.missing(id) }
        context.delete(row); try context.save()
    }
    private func checkpoint(node id: String) throws -> NSManagedObject? {
        try one("Checkpoint", "node", id)
    }
    private func path(to target: String) throws -> ([String], NSManagedObject?) {
        let nodeRequest = NSFetchRequest<NSDictionary>(entityName: "Node")
        nodeRequest.resultType = .dictionaryResultType
        nodeRequest.propertiesToFetch = ["id", "parent", "gapBefore"]
        nodeRequest.fetchBatchSize = 0 // Metadata only; benchmark records this whole-graph index cost.
        let rows = try context.fetch(nodeRequest)
        var parents: [String: String] = [:]
        var gaps: Set<String> = []
        parents.reserveCapacity(rows.count)
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            parents[id] = row["parent"] as? String ?? ""
            if row["gapBefore"] as? Bool == true { gaps.insert(id) }
        }
        let checkpoints = Set(try fetch("Checkpoint").compactMap { str($0, "node") })
        var backwards: [String] = []; var seen: Set<String> = []; var cursor: String? = target
        while let id = cursor {
            guard seen.insert(id).inserted else { throw ProofError.gap("cycle") }
            guard let parent = parents[id] else { throw ProofError.gap("missing " + id) }
            if checkpoints.contains(id) {
                return (backwards.reversed(), try checkpoint(node: id))
            }
            backwards.append(id)
            cursor = parent.isEmpty ? nil : parent
            if cursor != nil && gaps.contains(id) { throw ProofError.gap("before " + id) }
        }
        return (backwards.reversed(), nil)
    }
    private func effectByteCounts(_ ids: [String]) throws -> [String: Int] {
        guard !ids.isEmpty else { return [:] }
        let request = NSFetchRequest<NSDictionary>(entityName: "Effect")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["node", "valueBytes", "commandBytes"]
        request.predicate = NSPredicate(format: "node IN %@", ids)
        var counts: [String: Int] = [:]
        for row in try context.fetch(request) {
            guard let id = row["node"] as? String else { continue }
            let value = (row["valueBytes"] as? NSNumber)?.intValue ?? 0
            let command = (row["commandBytes"] as? NSNumber)?.intValue ?? 0
            counts[id, default: 0] += value + command
        }
        return counts
    }
    public func planPage(_ planID: String, offset: Int, maxEntries: Int? = nil) throws -> PlanPage {
        guard let plan = try one("Plan", "id", planID), let target = str(plan, "target") else {
            throw ProofError.missing(planID)
        }
        let (path, _) = try path(to: target)
        let bound = min(maxEntries ?? limits.pageEntries, limits.pageEntries)
        guard offset >= 0, bound > 0 else { throw ProofError.refused("page") }
        var ids: [String] = []; var bytes = 0
        let candidates = Array(path.dropFirst(offset).prefix(bound))
        let counts = try effectByteCounts(candidates)
        for id in candidates {
            let count = counts[id, default: 0]
            if !ids.isEmpty && bytes + count > limits.pageBytes { break }
            if count > limits.pageBytes { throw ProofError.refused("single page record bytes") }
            ids.append(id); bytes += count
        }
        // Fetch only the selected page's opaque material after deciding its
        // byte limit from normalized length columns.
        let material = ids.isEmpty ? [] : try fetch("Effect", NSPredicate(format: "node IN %@", ids))
        let actual = material.reduce(0) {
            $0 + (($1.value(forKey: "value") as? Data)?.count ?? 0) +
                 (($1.value(forKey: "command") as? Data)?.count ?? 0)
        }
        guard actual == bytes else { throw ProofError.gap("effect length mismatch") }
        return PlanPage(nodeIDs: ids, bytesRead: actual, advertisedBytes: bytes,
                        hasMore: offset + ids.count < path.count)
    }
    public func reconstruct(scope id: String, node target: String) throws -> RecoveryResult {
        guard let row = try one("Node", "id", target), str(row, "scope") == id else { throw ProofError.missing(target) }
        let (ids, baseline) = try path(to: target)
        var state: [String: String] = [:]; var bytes = 0
        if let snapshot = baseline?.value(forKey: "snapshot") as? Data {
            state = try JSONDecoder().decode([String: String].self, from: snapshot)
            bytes += snapshot.count
        }
        for batchStart in stride(from: 0, to: ids.count, by: 32) {
            let batch = Array(ids[batchStart..<min(ids.count, batchStart + 32)])
            let effects = try fetch("Effect", NSPredicate(format: "node IN %@", batch),
                                    sort: [NSSortDescriptor(key: "ordinal", ascending: true)])
            var grouped: [String: [NSManagedObject]] = [:]
            for effect in effects { grouped[str(effect, "node")!, default: []].append(effect) }
            for groupID in batch {
                for effect in grouped[groupID] ?? [] {
                    let key = str(effect, "key")!
                    let value = effect.value(forKey: "value") as? Data
                    bytes += (value?.count ?? 0) + ((effect.value(forKey: "command") as? Data)?.count ?? 0)
                    if key == "*", let value { state = try JSONDecoder().decode([String: String].self, from: value) }
                    else if let value { state[key] = String(decoding: value, as: UTF8.self) }
                    else { state.removeValue(forKey: key) }
                }
            }
        }
        return RecoveryResult(state: state, recordsVisited: ids.count, bytesRead: bytes,
                              baseline: baseline.flatMap { str($0, "node") })
    }
    public func references(store id: String) throws -> Set<Resource> {
        let rows = try fetch("Reference", NSPredicate(format: "store == %@", id))
        return Set(rows.map { Resource(store: id, key: str($0, "key")!, version: str($0, "version")!) })
    }
    public func fileFootprint() throws -> Int64 {
        var total: Int64 = 0
        for file in [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")] {
            if !FileManager.default.fileExists(atPath: file.path) { continue }
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let size = attrs[.size] as? NSNumber else { throw ProofError.refused("unreadable store footprint") }
            total += size.int64Value
        }
        return total
    }
}

public struct PruneResult: Sendable {
    public let removedGroups: Int
    public let retainedGroups: Int
    public let unmetTarget: Bool
}

extension HistoryStore {
    public func prune(targetGroups: Int) throws -> PruneResult {
        guard targetGroups >= 0 else { throw ProofError.refused("retention target") }
        let nodes = try fetch("Node")
        var byID: [String: NSManagedObject] = [:]
        byID.reserveCapacity(nodes.count)
        for node in nodes { byID[str(node, "id")!] = node }
        var protected: Set<String> = []
        func protectPath(_ start: String?, until: String? = nil, detailed: Bool = false) throws {
            var cursor = start
            var visited: Set<String> = []
            while let id = cursor {
                guard visited.insert(id).inserted else { throw ProofError.gap("protected cycle") }
                guard let row = byID[id] else { throw ProofError.gap("protected " + id) }
                protected.insert(id)
                if id == until { return }
                if !detailed { if try checkpoint(node: id) != nil { return } }
                cursor = str(row, "parent")
            }
            if until != nil { throw ProofError.gap("held segment boundary") }
        }
        var floors: [String: String] = [:]
        for row in try fetch("Scope") {
            if let floor = str(row, "undoFloor") {
                floors[str(row, "id")!] = floor
                try protectPath(str(row, "head"), until: floor, detailed: true)
            } else {
                try protectPath(str(row, "head"))
            }
        }
        for row in try fetch("Redo") {
            let floor = floors[str(row, "scope")!]
            try protectPath(str(row, "node"), until: floor, detailed: floor != nil)
        }
        for row in try fetch("Checkpoint") {
            if let id = str(row, "node") { protected.insert(id) }
        }
        for row in try fetch("Hold") {
            let id = str(row, "node")!
            if str(row, "kind") == "history" { try protectPath(id, until: str(row, "until"), detailed: true) }
            else { protected.insert(id) }
        }
        for row in try fetch("Plan") { try protectPath(str(row, "target")) }
        let removable = nodes.filter { !protected.contains(str($0, "id")!) }
            .sorted { ($0.value(forKey: "sequence") as? Int64 ?? 0) < ($1.value(forKey: "sequence") as? Int64 ?? 0) }
        let removeCount = min(removable.count, max(0, nodes.count - targetGroups))
        let removeIDs = removable.prefix(removeCount).map { str($0, "id")! }
        let removing = Set(removeIDs)
        for batchStart in stride(from: 0, to: removeIDs.count, by: 256) {
            let batch = Array(removeIDs[batchStart..<min(removeIDs.count, batchStart + 256)])
            for child in try fetch("Node", NSPredicate(format: "parent IN %@", batch)) {
                if !removing.contains(str(child, "id")!) {
                    child.setValue(true, forKey: "gapBefore")
                }
            }
            for effect in try fetch("Effect", NSPredicate(format: "node IN %@", batch)) {
                context.delete(effect)
            }
            for ref in try fetch("Reference", NSPredicate(format: "owner IN %@", batch)) {
                context.delete(ref)
            }
            for row in try fetch("Node", NSPredicate(format: "id IN %@", batch)) {
                context.delete(row)
            }
            try context.save()
            context.reset()
        }
        let retained = nodes.count - removeCount
        return PruneResult(removedGroups: removeCount, retainedGroups: retained,
                           unmetTarget: retained > targetGroups)
    }
}

extension HistoryStore {
    // Fixture construction uses an explicit structural fork; interactive restoration still
    // submits a new accepted group through restore(scope:target:).
    public func forkFixture(scope id: String, from ancestor: String) throws {
        guard let row = try one("Node", "id", ancestor), str(row, "scope") == id else {
            throw ProofError.missing(ancestor)
        }
        let owner = try scope(id)
        owner.setValue(ancestor, forKey: "head"); owner.setValue(nil, forKey: "redo")
        try flush()
    }
    public func dropCheckpoint(_ id: String) throws {
        guard let row = try one("Checkpoint", "id", id) else { throw ProofError.missing(id) }
        for ref in try fetch("Reference", NSPredicate(format: "owner == %@", id)) { context.delete(ref) }
        context.delete(row)
        try flush()
    }
    public func historyPage(scope id: String, offset: Int, count: Int) throws -> [NodeInfo] {
        guard offset >= 0, count > 0, count <= limits.pageEntries else { throw ProofError.refused("history page") }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Node")
        request.predicate = NSPredicate(format: "scope == %@", id)
        request.fetchOffset = offset; request.fetchLimit = count
        request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: false)]
        request.includesPropertyValues = true
        let rows = try context.fetch(request)
        var bytes = 0
        return try rows.map { row in
            let info = NodeInfo(id: str(row, "id")!, parent: str(row, "parent"),
                                origin: str(row, "origin"), kind: str(row, "kind")!,
                                gapBefore: row.value(forKey: "gapBefore") as? Bool ?? false)
            bytes += info.id.utf8.count + (info.parent?.utf8.count ?? 0) +
                     (info.origin?.utf8.count ?? 0) + info.kind.utf8.count
            guard bytes <= limits.pageBytes else { throw ProofError.refused("history page bytes") }
            return info
        }
    }
}
