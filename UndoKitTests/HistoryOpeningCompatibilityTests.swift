// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation
@testable import UndoKit
import XCTest

@MainActor final class HistoryOpeningCompatibilityTests: XCTestCase {
    func testWrongWorkingIdentityRefusesWithoutChangingHistoryArtifacts() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let identity = UUID()
        let store = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .create)
        try await store.close()
        let before = try artifacts(at: url)
        await assertRefusal(at: url, identity: UUID(), cause: .identityConflict)
        XCTAssertEqual(try artifacts(at: url), before)
        let reopened = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .existing)
        try await reopened.close()
    }

    func testMissingOpenModesDoNotCreateHistoryOrDirectories() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("missing")
        let url = parent.appendingPathComponent("History.sqlite")
        for access in [HistoryStoreAccess.readOnly, .readWrite] {
            await assertRefusal(at: url, identity: UUID(), cause: .missingHistory, access: access)
            await assertRefusal(at: url, identity: UUID(), cause: .missingHistory,
                                mode: .independentCopy(sourceWorkingIdentity: UUID()), access: access)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        await assertRefusal(at: url, identity: UUID(), cause: .identityConflict,
                            mode: .create, access: .readOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    func testCorruptSQLiteIsPreservedInBothAccessModes() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        // A recognized SQLite header is insufficient evidence of a readable store.
        try (Data("SQLite format 3\0".utf8) + Data(repeating: 0, count: 200)).write(to: url)
        let before = try artifacts(at: url)
        for access in [HistoryStoreAccess.readOnly, .readWrite] {
            await assertRefusal(at: url, identity: UUID(), cause: .corruptHistory, access: access)
            XCTAssertEqual(try artifacts(at: url), before)
        }
    }

    func testUnregisteredCompatibleModelIsRefusedAndPreserved() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await currentModel(in: directory)
        let url = directory.appendingPathComponent("Unregistered.sqlite")
        try makeFixture(at: url, model: model)
        let before = try artifacts(at: url)
        for access in [HistoryStoreAccess.readOnly, .readWrite] {
            await assertRefusal(at: url, identity: UUID(), cause: .compatibility, access: access)
            XCTAssertEqual(try artifacts(at: url), before)
        }
    }

    func testUnsupportedNewerModelIsRefusedAndPreserved() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await currentModel(in: directory)
        let field = NSAttributeDescription()
        field.name = "hypotheticalRequiredFutureField"
        field.attributeType = .stringAttributeType
        field.isOptional = false
        let entity = try XCTUnwrap(model.entitiesByName["HistoryStoreRecord"])
        entity.properties.append(field)
        model.versionIdentifiers = ["UnsupportedFutureFixture"]
        let url = directory.appendingPathComponent("Future.sqlite")
        try makeFixture(at: url, model: model)
        let before = try artifacts(at: url)
        for access in [HistoryStoreAccess.readOnly, .readWrite] {
            await assertRefusal(at: url, identity: UUID(), cause: .compatibility, access: access)
            XCTAssertEqual(try artifacts(at: url), before)
        }
    }

    func testUnrelatedModelIsRefusedAndPreserved() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "ForeignRecord"
        entity.managedObjectClassName = "NSManagedObject"
        let field = NSAttributeDescription()
        field.name = "foreignValue"
        field.attributeType = .integer64AttributeType
        entity.properties = [field]
        model.entities = [entity]
        let url = directory.appendingPathComponent("Foreign.sqlite")
        try makeFixture(at: url, model: model)
        let before = try artifacts(at: url)
        for access in [HistoryStoreAccess.readOnly, .readWrite] {
            await assertRefusal(at: url, identity: UUID(), cause: .compatibility, access: access)
            XCTAssertEqual(try artifacts(at: url), before)
        }
    }

    func testReadOnlySnapshotPreservesOriginalAndRequiresReopenForNewCommits() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let identity = UUID(), scope = UUID()
        let writer = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .create)
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await writer.openScope(scope, mode: .create, host: host)
        guard case .accepted = await engine.submit(HistoryCommand(fingerprint: Data("one".utf8), payload: payload(1))) else {
            XCTFail("Initial command failed")
            return
        }
        let before = try artifacts(at: url)
        let reader = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .existing, access: .readOnly)
        XCTAssertEqual(try reader.historyPage(scope: scope, limit: 10).map(\.sequence), [1])
        XCTAssertEqual(try artifacts(at: url), before)
        guard case .accepted = await engine.submit(HistoryCommand(fingerprint: Data("two".utf8), payload: payload(2))) else {
            XCTFail("Next command failed")
            return
        }
        XCTAssertEqual(try reader.historyPage(scope: scope, limit: 10).map(\.sequence), [1])
        let afterWrite = try artifacts(at: url)
        try await reader.close()
        XCTAssertEqual(try artifacts(at: url), afterWrite)
        let refreshed = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .existing, access: .readOnly)
        XCTAssertEqual(try refreshed.historyPage(scope: scope, limit: 10).map(\.sequence), [1, 2])
        try await refreshed.close()
        try await writer.close()
    }

    func testFailedIndependentCopyAdoptionPreservesOriginalBinding() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")
        let identity = UUID()
        let store = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .create)
        let originalStoreID = store.storeIdentity
        try await store.close()
        let before = try artifacts(at: url)
        await assertRefusal(at: url, identity: UUID(), cause: .identityConflict,
                            mode: .independentCopy(sourceWorkingIdentity: UUID()))
        XCTAssertEqual(try artifacts(at: url), before)
        await assertRefusal(at: url, identity: identity, cause: .identityConflict,
                            mode: .independentCopy(sourceWorkingIdentity: identity))
        XCTAssertEqual(try artifacts(at: url), before)
        await assertRefusal(at: url, identity: UUID(), cause: .invalidInput,
                            mode: .independentCopy(sourceWorkingIdentity: identity), access: .readOnly)
        XCTAssertEqual(try artifacts(at: url), before)
        let reopened = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .existing)
        XCTAssertEqual(reopened.storeIdentity, originalStoreID)
        try await reopened.close()
    }

    // Internal Core Data access is fixture arrangement only. Success/refusal and
    // preservation assertions all go through the public store API and owned bytes.
    private func currentModel(in directory: URL) async throws -> NSManagedObjectModel {
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("Model.sqlite"),
                                                workingIdentity: UUID(), mode: .create)
        let model = try XCTUnwrap(store.container.managedObjectModel.copy() as? NSManagedObjectModel)
        try await store.close()
        return model
    }

    private func makeFixture(at url: URL, model: NSManagedObjectModel) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType,
            configurationName: nil, at: url, options: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]])
        try coordinator.remove(store)
    }

    private func assertRefusal(at url: URL, identity: UUID, cause: HistoryFailureCause,
                               mode: HistoryOpenMode = .existing,
                               access: HistoryStoreAccess = .readWrite,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let unexpected = try await HistoryStore.open(at: url, workingIdentity: identity,
                                                         mode: mode, access: access)
            try await unexpected.close()
            XCTFail("Unsupported history opened", file: file, line: line)
        } catch let failure as HistoryFailure {
            XCTAssertEqual(failure.cause, cause, file: file, line: line)
            XCTAssertEqual(failure.stage, .admission, file: file, line: line)
        } catch {
            XCTFail("Unexpected opening error: \(error)", file: file, line: line)
        }
    }

    private func artifacts(at url: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["", "-wal", "-shm", "-journal"].compactMap { suffix in
            let file = URL(fileURLWithPath: url.path + suffix)
            return FileManager.default.fileExists(atPath: file.path)
                ? (suffix, try Data(contentsOf: file)) : nil
        })
    }
}

private struct PreviewBaselineRecipe: Decodable {
    struct Command: Decodable {
        let id: UUID
        let memberIDs: [UUID]
        let values: [Int]
    }
    let workingIdentity: UUID
    let scopeIdentity: UUID
    let retentionStoreIdentity: UUID
    let checkpointIdentity: UUID
    let codecFamily: String
    let codecVersion: Int
    let resourceFile: String
    let resourceObjectKey: String
    let resourceVersionKey: String
    let commands: [Command]
    let expectedHistorySequences: [Int64]
    let expectedHistoryKinds: [String]
    let expectedCheckpointValue: Int
    let expectedFinalHostValue: Int

    func payload(_ value: Int) -> HistoryPayload {
        HistoryPayload(family: codecFamily, version: codecVersion, data: Data(String(value).utf8))
    }

    var resource: HistoryObjectReference {
        HistoryObjectReference(storeID: retentionStoreIdentity, objectKey: resourceObjectKey,
                               versionKey: resourceVersionKey)
    }
}

/// Durable fixture host: effects and receipts share one atomic JSON replacement.
/// Canonical decimal codecs and the named resource are required for interpretation.
@MainActor private final class PreviewBaselineHost: HistoryHost {
    private struct Effect: Codable {
        let memberID: UUID
        let undo: Int
        let redo: Int
    }
    private struct State: Codable {
        var value = 0
        var receipts: [String: [Effect]] = [:]
    }
    private var state: State
    private let recipe: PreviewBaselineRecipe
    private let stateURL: URL
    private let resourceURL: URL
    var value: Int { state.value }
    var receiptCount: Int { state.receipts.count }

    init(recipe: PreviewBaselineRecipe, directory: URL) throws {
        self.recipe = recipe
        stateURL = directory.appendingPathComponent("host-state.json")
        resourceURL = directory.appendingPathComponent(recipe.resourceFile)
        state = FileManager.default.fileExists(atPath: stateURL.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)) : State()
    }

    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        if let prior = state.receipts[delivery.token.command.uuidString] { return outcome(prior) }
        guard FileManager.default.fileExists(atPath: resourceURL.path) else {
            return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable))
        }
        var next = state
        var effects: [Effect] = []
        for member in delivery.members {
            guard member.payload.family == recipe.codecFamily,
                  member.payload.version == recipe.codecVersion,
                  let text = String(data: member.payload.data, encoding: .utf8),
                  let value = Int(text), String(value) == text else {
                return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable))
            }
            effects.append(Effect(memberID: member.id, undo: next.value, redo: value))
            next.value = value
        }
        next.receipts[delivery.token.command.uuidString] = effects
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(next).write(to: stateURL, options: .atomic)
            state = next
            return outcome(effects)
        } catch { return .unresolved }
    }

    func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        guard let effects = state.receipts[token.command.uuidString] else { return .unresolved }
        return outcome(effects)
    }

    private func outcome(_ effects: [Effect]) -> HistoryHostOutcome {
        .accepted(effects.map { effect in
            HistoryEffect(memberID: effect.memberID, undo: recipe.payload(effect.undo),
                          redo: recipe.payload(effect.redo), resources: [recipe.resource])
        })
    }
}

extension HistoryOpeningCompatibilityTests {
    func testPreviewBaselineRecipeRetainsPairedHistoryStateCodecsAndResources() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #if SWIFT_PACKAGE
        let fixtures = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures")
        #else
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        #endif
        let recipeURL = fixtures.appendingPathComponent("preview-baseline.json")
        let recipe = try JSONDecoder().decode(PreviewBaselineRecipe.self, from: Data(contentsOf: recipeURL))
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(recipe.resourceFile),
                                        to: directory.appendingPathComponent(recipe.resourceFile))
        let host = try PreviewBaselineHost(recipe: recipe, directory: directory)
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
                                                workingIdentity: recipe.workingIdentity, mode: .create)
        let engine = try await store.openScope(recipe.scopeIdentity, mode: .create, host: host)
        for (index, command) in recipe.commands.enumerated() {
            let members = zip(command.memberIDs, command.values).map { id, value in
                HistoryMember(id: id, payload: recipe.payload(value))
            }
            guard case .accepted = await engine.submit(HistoryCommand(id: command.id,
                fingerprint: Data("preview command \(index + 1)".utf8), members: members)) else {
                XCTFail("Baseline command failed")
                return
            }
            if index == 0 {
                _ = try engine.createCheckpoint(id: recipe.checkpointIdentity, name: "Eleven",
                    state: recipe.payload(host.value), resources: [recipe.resource])
            }
        }
        guard case .accepted = await engine.undo() else {
            XCTFail("Baseline Undo failed")
            return
        }
        XCTAssertEqual(host.value, recipe.expectedCheckpointValue)
        guard case .accepted = await engine.redo() else {
            XCTFail("Baseline Redo failed")
            return
        }
        XCTAssertEqual(host.value, recipe.expectedFinalHostValue)

        // Capture matching host state/resources while all history admission is fenced.
        let paired = directory.appendingPathComponent("paired")
        try FileManager.default.createDirectory(at: paired, withIntermediateDirectories: false)
        let copiedURL = paired.appendingPathComponent("History.sqlite")
        try await store.withCoordinatedCopy(to: copiedURL) { _ in
            for name in ["host-state.json", recipe.resourceFile] {
                try FileManager.default.copyItem(at: directory.appendingPathComponent(name),
                                                to: paired.appendingPathComponent(name))
            }
            try FileManager.default.copyItem(at: recipeURL, to: paired.appendingPathComponent("recipe.json"))
        }
        try await store.close()
        let before = try artifacts(at: copiedURL)
        let reader = try await HistoryStore.open(at: copiedURL, workingIdentity: recipe.workingIdentity,
                                                 mode: .existing, access: .readOnly)
        XCTAssertEqual(try reader.historyPage(scope: recipe.scopeIdentity, limit: 10).map(\.sequence),
                       recipe.expectedHistorySequences)
        XCTAssertEqual(try reader.requiredObjects(in: recipe.retentionStoreIdentity, limit: 10).objects.map(\.reference),
                       [recipe.resource])
        try await reader.close()
        XCTAssertEqual(try artifacts(at: copiedURL), before)

        let reopenedHost = try PreviewBaselineHost(recipe: recipe, directory: paired)
        let reopened = try await HistoryStore.open(at: copiedURL, workingIdentity: recipe.workingIdentity, mode: .existing)
        let reopenedEngine = try await reopened.openScope(recipe.scopeIdentity, mode: .existing, host: reopenedHost)
        XCTAssertEqual(reopenedHost.value, recipe.expectedFinalHostValue)
        XCTAssertEqual(reopenedHost.receiptCount, 4)
        XCTAssertEqual(try reopenedEngine.historyPage(limit: 10).map { $0.kind.rawValue }, recipe.expectedHistoryKinds)
        XCTAssertEqual(try reopenedEngine.checkpoint(id: recipe.checkpointIdentity)?.state,
                       recipe.payload(recipe.expectedCheckpointValue))
        let entries = try reopenedEngine.historyPage(limit: 10)
        let plan = try reopenedEngine.beginRecoveryPlan(from: .checkpoint(recipe.checkpointIdentity),
            to: .group(entries[1].groupID), using: .acceptedEffects)
        let page = try reopenedEngine.recoveryPage(plan, limit: 10)
        XCTAssertEqual(page.steps.count, 1)
        let material = try reopenedEngine.recoveryMaterial(plan, groupID: entries[1].groupID, ordinal: 0)
        XCTAssertEqual(material.payload, recipe.payload(7))
        reopenedEngine.releaseRecoveryPlan(plan)
        try await reopened.close()

        // Opt-in export retains the concrete matched pair for candidate sealing.
        if let output = ProcessInfo.processInfo.environment["UNDOKIT_BASELINE_OUTPUT"] {
            let destination = URL(fileURLWithPath: output, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                XCTFail("Baseline export destination must be absent")
                return
            }
            try FileManager.default.copyItem(at: paired, to: destination)
        }
    }
}
