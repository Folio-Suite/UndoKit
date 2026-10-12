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
        guard case .accepted = await engine.submit(HistoryCommand(fingerprint: Data("one".utf8),
            payload: payload(1))) else {
            XCTFail("Initial command failed")
            return
        }
        let before = try artifacts(at: url)
        let reader = try await HistoryStore.open(at: url, workingIdentity: identity, mode: .existing, access: .readOnly)
        XCTAssertEqual(try reader.historyPage(scope: scope, limit: 10).map(\.sequence), [1])
        XCTAssertEqual(try artifacts(at: url), before)
        guard case .accepted = await engine.submit(HistoryCommand(fingerprint: Data("two".utf8),
            payload: payload(2))) else {
            XCTFail("Next command failed")
            return
        }
        XCTAssertEqual(try reader.historyPage(scope: scope, limit: 10).map(\.sequence), [1])
        let afterWrite = try artifacts(at: url)
        try await reader.close()
        XCTAssertEqual(try artifacts(at: url), afterWrite)
        let refreshed = try await HistoryStore.open(at: url,
            workingIdentity: identity, mode: .existing, access: .readOnly)
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

}

extension HistoryOpeningCompatibilityTests {
    func artifacts(at url: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["", "-wal", "-shm", "-journal"].compactMap { suffix in
            let file = URL(fileURLWithPath: url.path + suffix)
            return FileManager.default.fileExists(atPath: file.path)
                ? (suffix, try Data(contentsOf: file)) : nil
        })
    }
}
