// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor final class HistorySessionActionNameTests: XCTestCase {
    func testNativeNamesFollowTypedGroupsUndoRedoAndReopen() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let operation = try namedOperation(SessionTestHost())
        let configuration = applicationConfig(directory)
        let lease = SessionTestLease()
        let session = await owners.open(configuration: configuration, lease: lease, operations: [operation.erased])
        session.setNativeActionNameResolver { String(data: $0.data, encoding: .utf8) }
        let attachment = try session.attach(owner: lease)
        let manager = attachment.undoManager
        let commands = try session.commands(for: operation)
        XCTAssertFalse(manager.canUndo)
        XCTAssertEqual(manager.undoActionName, "")
        assertAccepted(await commands.submit(1))
        XCTAssertTrue(manager.canUndo)
        XCTAssertEqual(manager.undoActionName, "Change 1")
        XCTAssertTrue(manager.undoMenuItemTitle.contains("Change 1"))
        assertAccepted(await commands.submit(2))
        XCTAssertEqual(manager.undoActionName, "Change 2")
        manager.undo()
        XCTAssertFalse(manager.canUndo)
        XCTAssertEqual(manager.undoActionName, "")
        await session.waitForNativeOperations()
        XCTAssertEqual(manager.undoActionName, "Change 1")
        XCTAssertEqual(manager.redoActionName, "Change 2")
        XCTAssertTrue(manager.redoMenuItemTitle.contains("Change 2"))
        manager.redo()
        await session.waitForNativeOperations()
        XCTAssertEqual(manager.undoActionName, "Change 2")
        XCTAssertFalse(manager.canRedo)
        XCTAssertEqual(manager.redoActionName, "")
        attachment.disconnect()
        await session.close()
        XCTAssertEqual(manager.undoActionName, "")
        let reopened = await owners.open(
            configuration: applicationConfig(directory, scope: configuration.scope,
                working: configuration.workingIdentity, mode: .existing),
            lease: lease, operations: [operation.erased])
        reopened.setNativeActionNameResolver { _ in "Localized change" }
        let restored = try reopened.attach(owner: lease)
        XCTAssertTrue(restored.undoManager.canUndo)
        XCTAssertEqual(restored.undoManager.undoActionName, "Localized change")
        restored.disconnect()
        await reopened.close()
    }

    private func namedOperation(_ host: SessionTestHost) throws -> HistoryOperation<Int> {
        try HistoryOperation(
            operation: "named.integer", commandCodec: .json(), effectCodec: .json(), handler: host,
            fingerprint: { try JSONEncoder().encode($0) },
            metadata: { values in
                HistoryOperationMetadata(presentation: HistoryPayload(
                    family: "test.name", data: Data("Change \(values.last!)".utf8)))
            })
    }

    func testResolverChangesPublishCoherentNamesWithoutChangingAvailability() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let operation = try namedOperation(SessionTestHost())
        let lease = SessionTestLease()
        let session = await owners.open(
            configuration: applicationConfig(directory), lease: lease, operations: [operation.erased])
        let attachment = try session.attach(owner: lease)
        let manager = attachment.undoManager
        let observations = NameObservations()
        assertAccepted(await (try session.commands(for: operation)).submitGroup([1, 2]))
        XCTAssertEqual(manager.undoActionName, "")
        let token = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerCheckpoint, object: manager, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                observations.names.append(manager.undoActionName)
                XCTAssertTrue(manager.canUndo)
            }
        }
        session.setNativeActionNameResolver { _ in "Localized group" }
        XCTAssertEqual(manager.undoActionName, "Localized group")
        XCTAssertTrue(observations.names.contains("Localized group"))
        session.setNativeActionNameResolver { _ in throw CocoaError(.coderReadCorrupt) }
        XCTAssertEqual(manager.undoActionName, "")
        session.setNativeActionNameResolver { _ in "Replacement" }
        XCTAssertEqual(manager.undoActionName, "Replacement")
        session.setNativeActionNameResolver(nil)
        XCTAssertEqual(manager.undoActionName, "")
        XCTAssertTrue(manager.canUndo)
        NotificationCenter.default.removeObserver(token)
        attachment.disconnect()
        await session.close()
    }

    @MainActor private final class NameObservations {
        var names: [String] = []
    }

    func testUnresolvedSubmissionHidesNamesUntilReconciliationAndClearRetiresThem() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let host = SessionTestHost()
        let operation = try namedOperation(host)
        let lease = SessionTestLease()
        let session = await owners.open(
            configuration: applicationConfig(directory), lease: lease, operations: [operation.erased])
        session.setNativeActionNameResolver { String(data: $0.data, encoding: .utf8) }
        let attachment = try session.attach(owner: lease)
        let manager = attachment.undoManager
        let commands = try session.commands(for: operation)
        assertAccepted(await commands.submit(1))
        await host.pauseNextAndLoseReply()
        let submission = Task { await commands.submit(2) }
        await host.waitUntilPaused()
        XCTAssertFalse(manager.canUndo)
        XCTAssertEqual(manager.undoActionName, "")
        await host.resume()
        guard case .unresolved = await submission.value else {
            XCTFail("Expected unresolved reply")
            return
        }
        XCTAssertFalse(manager.canUndo)
        XCTAssertEqual(manager.undoActionName, "")
        _ = await session.reconcile()
        XCTAssertTrue(manager.canUndo)
        XCTAssertEqual(manager.undoActionName, "Change 2")
        _ = try session.advanced.clearHistory(adopting: HistoryPayload(family: "baseline", data: Data()))
        XCTAssertFalse(manager.canUndo)
        XCTAssertEqual(manager.undoActionName, "")
        XCTAssertEqual(manager.redoActionName, "")
        attachment.disconnect()
        await session.close()
    }
}
