// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import CoreData
import CryptoKit
import Foundation

public enum PackageFailure: Error, Equatable {
    case missingHistory, corruptHistory, unavailableHistory, newerSchema, unknownCodec
    case identityMismatch, unresolved, injectedFailure, destinationExists, missingResource, corruptResource
    case unusable, rollbackFailed(String)
}

public enum HistoryKind: String { case action, checkpoint, baseline, displaced }
public enum PromotionFault: String { case afterOriginalMoved, afterNewAttached, rollbackBlocked }

public struct ProbeSnapshot: Equatable {
    public let text: String
    public let resource: String
    public let history: [String]
    public let generation: Int
    public let recording: Bool
    public init(text: String, resource: String, history: [String], generation: Int, recording: Bool) {
        self.text = text; self.resource = resource; self.history = history
        self.generation = generation; self.recording = recording
    }
}

private struct Manifest: Codable {
    var schema: Int = 2
    var codec: String = "plain-v1"
    var identity: String = UUID().uuidString
    var generation: Int = 1
    var recording: Bool = true
    var expectedHistory: Bool = true
    var unresolved: Bool = false
}

private struct Contents: Codable {
    var scopes: [String: String] = [:]
    var resources: [String: String] = [:]
}

/// Disposable package host. Its main-actor calls serialize mutation and capture.
@MainActor public final class PackageProbe {
    private var url: URL
    private var manifest: Manifest
    private var contents: Contents
    private var coordinator: NSPersistentStoreCoordinator?
    private var store: NSPersistentStore?
    private var context: NSManagedObjectContext?
    private var unusable = false
    public var identity: String { manifest.identity }
    public var generation: Int { manifest.generation }
    private init(url: URL, manifest: Manifest, contents: Contents) {
        self.url = url; self.manifest = manifest; self.contents = contents
    }

    private static func model(_ version: Int) -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "Record"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let value = NSAttributeDescription()
            value.name = name; value.attributeType = type; value.isOptional = optional
            return value
        }
        var fields = [attribute("scope", .stringAttributeType), attribute("kind", .stringAttributeType),
                      attribute("value", .stringAttributeType), attribute("generation", .integer64AttributeType),
                      attribute("ordinal", .integer64AttributeType), attribute("resourceID", .stringAttributeType)]
        if version >= 2 { fields.append(attribute("codec", .stringAttributeType, optional: true)) }
        entity.properties = fields
        model.entities = [entity]
        model.versionIdentifiers = ["package-probe-v\(version)"]
        return model
    }

    private static func database(_ url: URL) -> URL { url.appendingPathComponent("History.sqlite") }
    private static func manifestURL(_ url: URL) -> URL { url.appendingPathComponent("manifest.json") }
    private static func contentsURL(_ url: URL) -> URL { url.appendingPathComponent("contents.json") }
    private static func resourceID(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func resourceURL(_ url: URL, id: String) -> URL {
        url.appendingPathComponent("Resources").appendingPathComponent(id + ".bin")
    }
    private func resource(id: String) throws -> String {
        if id.isEmpty { return "" }
        guard id.utf8.count == 64,
              id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw PackageFailure.corruptResource
        }
        guard let data = try? Data(contentsOf: Self.resourceURL(url, id: id)) else { throw PackageFailure.missingResource }
        guard Self.resourceID(data) == id, let text = String(data: data, encoding: .utf8) else {
            throw PackageFailure.corruptResource
        }
        return text
    }
    private func ensureUsable() throws {
        if unusable { throw PackageFailure.unusable }
    }
    private func validateResources() throws {
        for id in contents.resources.values { _ = try resource(id: id) }
        guard let context else {
            if manifest.expectedHistory { throw PackageFailure.unavailableHistory }
            return
        }
        let rows = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Record"))
        for row in rows {
            guard let id = row.value(forKey: "resourceID") as? String else { throw PackageFailure.corruptHistory }
            _ = try resource(id: id)
        }
    }
    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    private static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func attach(version: Int, migration: Bool = false) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: Self.model(version))
        let options: [AnyHashable: Any] = [NSSQLitePragmasOption: ["journal_mode": "WAL"],
                                          NSMigratePersistentStoresAutomaticallyOption: migration,
                                          NSInferMappingModelAutomaticallyOption: migration]
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                                        at: Self.database(url), options: options)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        self.coordinator = coordinator; self.store = store; self.context = context
    }
    private func detach() throws {
        if let context, context.hasChanges { try context.save() }
        if let store { try coordinator?.remove(store) }
        store = nil; coordinator = nil; context = nil
    }

    public static func create(at url: URL, historyFree: Bool = false, legacy: Bool = false) throws -> PackageProbe {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw PackageFailure.destinationExists }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        var manifest = Manifest()
        manifest.schema = legacy ? 1 : 2
        manifest.expectedHistory = !historyFree
        let probe = PackageProbe(url: url, manifest: manifest, contents: Contents())
        try writeJSON(manifest, to: manifestURL(url))
        try writeJSON(probe.contents, to: contentsURL(url))
        if !historyFree { try probe.attach(version: manifest.schema) }
        return probe
    }

    public static func open(at url: URL, expectedIdentity: String? = nil,
                            simulateUnavailable: Bool = false) throws -> PackageProbe {
        let manifest = try readJSON(Manifest.self, from: manifestURL(url))
        let contents = try readJSON(Contents.self, from: contentsURL(url))
        guard manifest.schema <= 2 else { throw PackageFailure.newerSchema }
        guard manifest.codec == "plain-v1" else { throw PackageFailure.unknownCodec }
        if let expectedIdentity, manifest.identity != expectedIdentity { throw PackageFailure.identityMismatch }
        if manifest.expectedHistory {
            guard FileManager.default.fileExists(atPath: database(url).path) else { throw PackageFailure.missingHistory }
            if simulateUnavailable { throw PackageFailure.unavailableHistory }
            do {
                let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
                                                                                            at: database(url))
                guard model(manifest.schema).isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else {
                    throw PackageFailure.corruptHistory
                }
            } catch { throw PackageFailure.corruptHistory }
        }
        let probe = PackageProbe(url: url, manifest: manifest, contents: contents)
        if manifest.expectedHistory {
            do { try probe.attach(version: manifest.schema) }
            catch { throw PackageFailure.corruptHistory }
        }
        do { try probe.validateResources() }
        catch {
            try? probe.detach()
            throw error
        }
        return probe
    }

    public func close() throws { try detach() }
    public func snapshot(scope: String) throws -> ProbeSnapshot {
        let resource = try resource(id: contents.resources[scope] ?? "")
        return ProbeSnapshot(text: contents.scopes[scope] ?? "", resource: resource,
                             history: try records(scope: scope, kind: "action"),
                             generation: manifest.generation, recording: manifest.recording)
    }
    private func rows(scope: String, kind: String) throws -> [NSManagedObject] {
        guard let context else {
            if manifest.expectedHistory { throw PackageFailure.unavailableHistory }
            return []
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
        request.predicate = NSPredicate(format: "scope == %@ AND kind == %@ AND generation == %d",
                                        scope, kind, manifest.generation)
        request.sortDescriptors = [NSSortDescriptor(key: "ordinal", ascending: true)]
        return try context.fetch(request)
    }
    private func records(scope: String, kind: String) throws -> [String] {
        try rows(scope: scope, kind: kind).compactMap { $0.value(forKey: "value") as? String }
    }
    public func historicalResources(scope: String, kind: HistoryKind) throws -> [String] {
        try rows(scope: scope, kind: kind.rawValue).map { row in
            guard let id = row.value(forKey: "resourceID") as? String else { throw PackageFailure.corruptHistory }
            return try resource(id: id)
        }
    }
    private func record(scope: String, kind: String, value: String, resourceID: String) throws {
        guard let context else {
            if manifest.expectedHistory { throw PackageFailure.unavailableHistory }
            return
        }
        do {
            let row = NSEntityDescription.insertNewObject(forEntityName: "Record", into: context)
            row.setValue(scope, forKey: "scope")
            row.setValue(kind, forKey: "kind")
            row.setValue(value, forKey: "value")
            row.setValue(resourceID, forKey: "resourceID")
            row.setValue(manifest.generation, forKey: "generation")
            let count = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Record"))
            row.setValue(count, forKey: "ordinal")
            if manifest.schema >= 2 { row.setValue(manifest.codec, forKey: "codec") }
            if failNextHistorySaveAfterInsert {
                failNextHistorySaveAfterInsert = false
                throw PackageFailure.injectedFailure
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// A deterministic failure hook after insertion and before the Core Data save.
    public var failNextHistorySaveAfterInsert = false

    public func save(scope: String, text: String, resource: String) throws {
        try ensureUsable()
        guard !manifest.unresolved else { throw PackageFailure.unresolved }
        try validateResources()
        let previous = contents
        let data = Data(resource.utf8)
        let id = resource.isEmpty ? "" : Self.resourceID(data)
        let resourceURL = Self.resourceURL(url, id: id)
        let newResource = !id.isEmpty && !FileManager.default.fileExists(atPath: resourceURL.path)
        contents.scopes[scope] = text; contents.resources[scope] = id
        do {
            if newResource { try data.write(to: resourceURL, options: .atomic) }
            else { _ = try self.resource(id: id) }
            try Self.writeJSON(contents, to: Self.contentsURL(url))
            if manifest.recording { try record(scope: scope, kind: "action", value: text, resourceID: id) }
        } catch {
            contents = previous
            try? Self.writeJSON(previous, to: Self.contentsURL(url))
            if newResource { try? FileManager.default.removeItem(at: resourceURL) }
            throw error
        }
    }
    public func setRecording(_ enabled: Bool) throws {
        try ensureUsable()
        guard !manifest.unresolved else { throw PackageFailure.unresolved }
        if enabled && !manifest.recording {
            for (scope, text) in contents.scopes {
                try record(scope: scope, kind: "baseline", value: text, resourceID: contents.resources[scope] ?? "")
            }
        }
        manifest.recording = enabled
        try Self.writeJSON(manifest, to: Self.manifestURL(url))
    }
    public func checkpoint(scope: String) throws {
        try ensureUsable()
        guard !manifest.unresolved else { throw PackageFailure.unresolved }
        let state = try snapshot(scope: scope)
        try record(scope: scope, kind: "checkpoint", value: state.text, resourceID: contents.resources[scope] ?? "")
    }
    public func checkpoints(scope: String) throws -> [String] { try records(scope: scope, kind: "checkpoint") }
    public func baseline(scope: String) throws -> [String] { try records(scope: scope, kind: "baseline") }

    /// Core Data copies the SQLite store and its active journal under a serialized host boundary.
    public func capture(to destination: URL, independent: Bool) throws {
        try ensureUsable()
        guard !manifest.unresolved else { throw PackageFailure.unresolved }
        try validateResources()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw PackageFailure.destinationExists }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try Self.writeJSON(contents, to: Self.contentsURL(stage))
        var copyManifest = manifest
        if independent { copyManifest.identity = UUID().uuidString }
        try Self.writeJSON(copyManifest, to: Self.manifestURL(stage))
        try FileManager.default.copyItem(at: url.appendingPathComponent("Resources"),
                                         to: stage.appendingPathComponent("Resources"))
        if manifest.expectedHistory {
            guard let coordinator else { throw PackageFailure.unavailableHistory }
            try coordinator.replacePersistentStore(at: Self.database(stage), destinationOptions: nil,
                                                   withPersistentStoreFrom: Self.database(url), sourceOptions: nil,
                                                   ofType: NSSQLiteStoreType)
        }
        let validated = try Self.open(at: stage, expectedIdentity: copyManifest.identity)
        try validated.close()
        try FileManager.default.moveItem(at: stage, to: destination)
    }
    public func move(to destination: URL, simulateFailure: Bool = false) throws {
        try ensureUsable()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw PackageFailure.destinationExists }
        let original = url
        try detach()
        do {
            if simulateFailure { throw PackageFailure.injectedFailure }
            try FileManager.default.moveItem(at: original, to: destination)
            url = destination
            if manifest.expectedHistory { try attach(version: manifest.schema) }
        } catch {
            try? detach()
            if !FileManager.default.fileExists(atPath: original.path),
               FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: destination, to: original)
            }
            url = original
            if manifest.expectedHistory { try attach(version: manifest.schema) }
            throw error
        }
    }
    public func restore(from source: PackageProbe, scope: String,
                        simulateFailureAfterState: Bool = false) throws {
        try ensureUsable()
        guard !manifest.unresolved else { throw PackageFailure.unresolved }
        try source.validateResources()
        let displaced = try snapshot(scope: scope)
        let selected = try source.snapshot(scope: scope)
        let staged = url.deletingLastPathComponent().appendingPathComponent(".restore-\(UUID().uuidString)")
        try capture(to: staged, independent: false)
        defer { try? FileManager.default.removeItem(at: staged) }
        let edited = try Self.open(at: staged, expectedIdentity: identity)
        defer { try? edited.close() }
        try edited.save(scope: scope, text: selected.text, resource: selected.resource)
        if simulateFailureAfterState {
            try edited.close()
            throw PackageFailure.injectedFailure
        }
        let displacedID = displaced.resource.isEmpty ? "" : Self.resourceID(Data(displaced.resource.utf8))
        try edited.record(scope: scope, kind: "displaced", value: displaced.text, resourceID: displacedID)
        try edited.close()
        try promote(staged, next: manifest, fault: nil)
    }
    public func displaced(scope: String) throws -> [String] { try records(scope: scope, kind: "displaced") }
    public func omitHistory(simulateFailure: Bool = false, promotionFault: PromotionFault? = nil) throws {
        try ensureUsable()
        guard !manifest.unresolved else { throw PackageFailure.unresolved }
        guard manifest.expectedHistory else { return }
        let staged = url.deletingLastPathComponent().appendingPathComponent(".omission-\(UUID().uuidString)")
        try capture(to: staged, independent: false)
        defer { try? FileManager.default.removeItem(at: staged) }
        let edited = try Self.open(at: staged, expectedIdentity: identity)
        defer { try? edited.close() }
        guard let context = edited.context else { throw PackageFailure.missingHistory }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
        for row in try context.fetch(request) { context.delete(row) }
        try context.save()
        let current = Set(edited.contents.resources.values)
        let resourceDirectory = staged.appendingPathComponent("Resources")
        for file in try FileManager.default.contentsOfDirectory(at: resourceDirectory, includingPropertiesForKeys: nil) {
            let id = file.deletingPathExtension().lastPathComponent
            if !current.contains(id) { try FileManager.default.removeItem(at: file) }
        }
        edited.manifest.generation += 1
        try Self.writeJSON(edited.manifest, to: Self.manifestURL(staged))
        try edited.close()
        if simulateFailure { throw PackageFailure.injectedFailure }
        try promote(staged, next: edited.manifest, fault: promotionFault)
    }

    private func promote(_ staged: URL, next: Manifest, fault: PromotionFault?) throws {
        let original = url.deletingLastPathComponent().appendingPathComponent(".original-\(UUID().uuidString)")
        let previous = manifest
        let previousContents = contents
        let adoptedContents = try Self.readJSON(Contents.self, from: Self.contentsURL(staged))
        try detach()
        do {
            try FileManager.default.moveItem(at: url, to: original)
            if fault == .afterOriginalMoved { throw PackageFailure.injectedFailure }
            try FileManager.default.moveItem(at: staged, to: url)
            try attach(version: next.schema)
            manifest = next
            contents = adoptedContents
            if fault == .afterNewAttached || fault == .rollbackBlocked { throw PackageFailure.injectedFailure }
            try FileManager.default.removeItem(at: original)
        } catch {
            do { try detach() }
            catch {
                unusable = true
                throw PackageFailure.rollbackFailed(FileManager.default.fileExists(atPath: original.path) ? original.path : url.path)
            }
            if FileManager.default.fileExists(atPath: original.path) {
                do {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    if fault == .rollbackBlocked { throw PackageFailure.injectedFailure }
                    try FileManager.default.moveItem(at: original, to: url)
                } catch {
                    unusable = true
                    throw PackageFailure.rollbackFailed(original.path)
                }
            }
            manifest = previous
            contents = previousContents
            do {
                if previous.expectedHistory { try attach(version: previous.schema) }
            } catch {
                unusable = true
                throw PackageFailure.rollbackFailed(url.path)
            }
            throw error
        }
    }

    public func migrate(simulateInterruption: Bool = false, promotionFault: PromotionFault? = nil) throws {
        try ensureUsable()
        guard manifest.schema == 1 else { return }
        let staged = url.deletingLastPathComponent().appendingPathComponent(".migration-\(UUID().uuidString)")
        try capture(to: staged, independent: false)
        defer { try? FileManager.default.removeItem(at: staged) }
        var stagedManifest = manifest
        stagedManifest.schema = 2
        try Self.writeJSON(stagedManifest, to: Self.manifestURL(staged))
        let upgrade = PackageProbe(url: staged, manifest: stagedManifest, contents: contents)
        try upgrade.attach(version: 2, migration: true)
        try upgrade.detach()
        let validated = try Self.open(at: staged, expectedIdentity: identity)
        try validated.close()
        if simulateInterruption { throw PackageFailure.injectedFailure }
        try promote(staged, next: stagedManifest, fault: promotionFault)
    }
    /// Fixture control for explicit compatibility inputs.
    public func fixtureManifest(schema: Int? = nil, codec: String? = nil, unresolved: Bool? = nil) throws {
        try ensureUsable()
        if let schema { manifest.schema = schema }
        if let codec { manifest.codec = codec }
        if let unresolved { manifest.unresolved = unresolved }
        try Self.writeJSON(manifest, to: Self.manifestURL(url))
    }

    /// Fixture control for a missing or tampered immutable historical asset.
    public func fixtureDamageHistoricalResource(scope: String, kind: HistoryKind,
                                                index: Int = 0, corrupt: Bool = false) throws {
        try ensureUsable()
        let matching = try rows(scope: scope, kind: kind.rawValue)
        guard matching.indices.contains(index),
              let id = matching[index].value(forKey: "resourceID") as? String,
              !id.isEmpty else { throw PackageFailure.missingResource }
        let location = Self.resourceURL(url, id: id)
        if corrupt { try Data("tampered".utf8).write(to: location, options: .atomic) }
        else { try FileManager.default.removeItem(at: location) }
    }
}
