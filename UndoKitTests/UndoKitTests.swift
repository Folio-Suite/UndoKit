// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor final class CounterHost: HistoryHost {
    private struct Receipt: Codable {
        let accepted: Bool
        let memberIDs: [UUID]
        let priorValues: [Int]
        let newValues: [Int]
    }

    private struct State: Codable {
        var value = 0
        var receipts: [UUID: Receipt] = [:]
    }

    private let url: URL
    private var state: State
    var deliveries = 0
    var rejectNext = false
    var loseReplyAfterSave = false
    var pauseBeforeSave = false
    private var deliveryContinuation: CheckedContinuation<Void, Never>?

    init(url: URL) throws {
        self.url = url
        state = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State()
    }

    var value: Int { state.value }

    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        deliveries += 1
        if pauseBeforeSave {
            pauseBeforeSave = false
            await withCheckedContinuation { deliveryContinuation = $0 }
        }
        if let receipt = state.receipts[delivery.token.command] { return outcome(receipt) }
        let rejected = rejectNext
        rejectNext = false
        let old = state.value
        var values: [Int] = []
        for member in delivery.members {
            guard let text = String(bytes: member.payload.data, encoding: .utf8),
                  let value = Int(text) else { return .unresolved }
            values.append(value)
        }
        let prior = Array(repeating: old, count: values.count)
        let receipt = Receipt(accepted: !rejected, memberIDs: delivery.members.map(\.id),
                              priorValues: prior, newValues: values)
        if !rejected { state.value = values.last ?? old }
        state.receipts[delivery.token.command] = receipt
        do { try JSONEncoder().encode(state).write(to: url, options: .atomic) } catch { return .unresolved }
        if loseReplyAfterSave { loseReplyAfterSave = false; return .unresolved }
        return outcome(receipt)
    }

    func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        guard let receipt = state.receipts[token.command] else { return .unresolved }
        return outcome(receipt)
    }

    func resumeDelivery() {
        deliveryContinuation?.resume()
        deliveryContinuation = nil
    }

    private func outcome(_ receipt: Receipt) -> HistoryHostOutcome {
        guard receipt.accepted else { return .rejected }
        return .accepted(zip(receipt.memberIDs, zip(receipt.priorValues, receipt.newValues)).map { id, values in
            HistoryEffect(memberID: id, undo: payload(values.0), redo: payload(values.1))
        })
    }
}

func testDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("UndoKitTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func payload(_ value: Int) -> HistoryPayload {
    HistoryPayload(family: "counter.set", data: Data(String(value).utf8))
}

@MainActor final class UndoKitTests: XCTestCase {
    func testAcceptedCommandSurvivesReopenAndCanUndo() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = UUID(), workingID = UUID()
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let store = directory.appendingPathComponent("History.sqlite")
        let engine = try await HistoryEngine.open(at: store, scope: scope, workingIdentity: workingID,
                                                   mode: .create, host: host)
        let command = HistoryCommand(fingerprint: Data("set 7".utf8), payload: payload(7))
        guard case .accepted = await engine.submit(command) else {
            XCTFail("Host change was not accepted")
            return
        }
        XCTAssertEqual(host.value, 7)
        XCTAssertTrue(engine.snapshot.canUndo)
        try await engine.close()

        let reopenedHost = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let reopened = try await HistoryEngine.open(at: store, scope: scope, workingIdentity: workingID,
                                                     mode: .existing, host: reopenedHost)
        XCTAssertTrue(reopened.snapshot.canUndo)
        guard case .accepted = await reopened.undo() else {
            XCTFail("Durable inverse was not accepted")
            return
        }
        XCTAssertEqual(reopenedHost.value, 0)
        XCTAssertTrue(reopened.snapshot.canRedo)
        guard case .accepted = await reopened.redo() else {
            XCTFail("Durable Redo was not accepted")
            return
        }
        let entries = try reopened.historyPage(limit: 10)
        XCTAssertEqual(entries[2].sourceGroupID, entries[0].groupID)
        XCTAssertEqual(entries[2].compensationGroupID, entries[1].groupID)
        try await reopened.close()
    }

    func testAcceptedHostEffectReconcilesAfterLostReplyAndReopen() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = UUID(), workingID = UUID()
        let hostURL = directory.appendingPathComponent("host.json")
        let storeURL = directory.appendingPathComponent("History.sqlite")
        let host = try CounterHost(url: hostURL)
        host.loseReplyAfterSave = true
        let engine = try await HistoryEngine.open(at: storeURL, scope: scope,
                                                   workingIdentity: workingID, mode: .create, host: host)
        let command = HistoryCommand(fingerprint: Data("set 9".utf8), payload: payload(9))
        guard case .failure(let failure) = await engine.submit(command) else {
            XCTFail("Lost reply must suspend history")
            return
        }
        XCTAssertEqual(failure.disposition, .suspended)
        XCTAssertEqual(host.value, 9)
        XCTAssertFalse(engine.snapshot.canUndo)
        try await engine.close()

        let recoveredHost = try CounterHost(url: hostURL)
        let recovered = try await HistoryEngine.open(at: storeURL, scope: scope,
                                                      workingIdentity: workingID, mode: .existing, host: recoveredHost)
        XCTAssertEqual(recoveredHost.deliveries, 0)
        XCTAssertFalse(recovered.snapshot.isSuspended)
        XCTAssertTrue(recovered.snapshot.canUndo)
        try await recovered.close()
    }

    func testUndoDepthCountsCompleteGroupsAndRejectedInverseStopsTraversal() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(
            at: directory.appendingPathComponent("History.sqlite"), scope: UUID(),
            workingIdentity: UUID(), mode: .create, host: host,
            limits: HistoryLimits(maxUndoGroups: 2)
        )
        for value in 1...3 {
            let result = await engine.submit(HistoryCommand(
                fingerprint: Data("set \(value)".utf8), payload: payload(value)
            ))
            guard case .accepted = result else {
                XCTFail("Command \(value) was not accepted")
                return
            }
        }
        guard case .accepted = await engine.undo() else {
            XCTFail("Latest group not reversible")
            return
        }
        XCTAssertEqual(host.value, 2)
        guard case .accepted = await engine.undo() else {
            XCTFail("Second group not reversible")
            return
        }
        XCTAssertEqual(host.value, 1)
        XCTAssertFalse(engine.snapshot.canUndo)
        XCTAssertTrue(engine.snapshot.canRedo)
        guard case .accepted = await engine.redo() else {
            XCTFail("Redo not available")
            return
        }
        XCTAssertEqual(host.value, 2)
        host.rejectNext = true
        guard case .rejected = await engine.undo() else {
            XCTFail("Rejected inverse was not reported")
            return
        }
        XCTAssertEqual(host.value, 2)
        XCTAssertFalse(engine.snapshot.canUndo)
        try await engine.close()
    }

    func testCheckpointRestorationPreservesDisplacedWorkAndIsUndoable() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(
            at: directory.appendingPathComponent("History.sqlite"), scope: UUID(),
            workingIdentity: UUID(), mode: .create, host: host
        )
        for value in 1...3 {
            guard case .accepted = await engine.submit(HistoryCommand(
                fingerprint: Data("set \(value)".utf8), payload: payload(value)
            )) else {
                XCTFail("Command was not accepted")
                return
            }
            if value == 1 { _ = try engine.createCheckpoint(name: "First", state: payload(1)) }
        }
        let checkpointInfo = try XCTUnwrap(engine.checkpoints(limit: 10).first)
        let savedState = try XCTUnwrap(engine.checkpoint(id: checkpointInfo.id)?.state)
        let restore = HistoryCommand(fingerprint: Data("restore first".utf8),
                                     payload: savedState, restorationOrigin: checkpointInfo.id)
        guard case .accepted = await engine.submit(restore) else {
            XCTFail("Restore not accepted")
            return
        }
        XCTAssertEqual(host.value, 1)
        guard case .accepted = await engine.undo() else {
            XCTFail("Restore not undoable")
            return
        }
        XCTAssertEqual(host.value, 3)
        guard case .accepted = await engine.redo() else {
            XCTFail("Restore not redoable")
            return
        }
        XCTAssertEqual(host.value, 1)
        let page = try engine.historyPage(limit: 10)
        XCTAssertEqual(page.count, 6)
        XCTAssertEqual(page[3].restorationOrigin, checkpointInfo.id)
        XCTAssertEqual(page[2].kind, .command)
        try await engine.close()
    }

    func testRejectedWholeGroupInverseNeverPartiallyChangesHostState() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(
            at: directory.appendingPathComponent("History.sqlite"), scope: UUID(),
            workingIdentity: UUID(), mode: .create, host: host
        )
        let group = HistoryCommand(fingerprint: Data("set 1 then 2 atomically".utf8), members: [
            HistoryMember(payload: payload(1)), HistoryMember(payload: payload(2))
        ])
        guard case .accepted = await engine.submit(group) else {
            XCTFail("Group was not accepted")
            return
        }
        XCTAssertEqual(host.value, 2)
        host.rejectNext = true
        guard case .rejected = await engine.undo() else {
            XCTFail("Inverse rejection was not reported")
            return
        }
        XCTAssertEqual(host.value, 2)
        XCTAssertFalse(engine.snapshot.canUndo)
        XCTAssertFalse(engine.snapshot.canRedo)
        let page = try engine.historyPage(limit: 10)
        XCTAssertEqual(page.count, 1)
        XCTAssertEqual(page[0].memberCount, 2)
        try await engine.close()
    }

    func testCloseReturnsQueuedUnstartedCommandWithoutHostDelivery() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(
            at: directory.appendingPathComponent("History.sqlite"), scope: UUID(),
            workingIdentity: UUID(), mode: .create, host: host
        )
        host.pauseBeforeSave = true
        let first = Task { await engine.submit(HistoryCommand(fingerprint: Data("first".utf8), payload: payload(1))) }
        for _ in 0..<100 where host.deliveries == 0 { await Task.yield() }
        let queued = Task { await engine.submit(HistoryCommand(fingerprint: Data("queued".utf8), payload: payload(2))) }
        await Task.yield()
        let release = Task { await Task.yield(); host.resumeDelivery() }
        try await engine.close()
        _ = await release.value
        guard case .accepted = await first.value else {
            XCTFail("Delivered first command lost")
            return
        }
        guard case .failure(let failure) = await queued.value else {
            XCTFail("Queued command executed during close")
            return
        }
        XCTAssertEqual(failure.stage, .admission)
        XCTAssertEqual(host.deliveries, 1)
        XCTAssertEqual(host.value, 1)
    }

    func testIndependentCopyRebindsWorkingIdentityAndPreservesOriginal() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = UUID(), originalID = UUID(), copyID = UUID()
        let originalHostURL = directory.appendingPathComponent("host.json")
        let originalStoreURL = directory.appendingPathComponent("History.sqlite")
        let host = try CounterHost(url: originalHostURL)
        let engine = try await HistoryEngine.open(at: originalStoreURL, scope: scope,
                                                   workingIdentity: originalID, mode: .create, host: host)
        guard case .accepted = await engine.submit(HistoryCommand(
            fingerprint: Data("set 5".utf8), payload: payload(5)
        )) else {
            XCTFail("Initial command failed")
            return
        }
        let copyDirectory = directory.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: copyDirectory, withIntermediateDirectories: true)
        let copyStoreURL = copyDirectory.appendingPathComponent("History.sqlite")
        try engine.copyStore(to: copyStoreURL)
        try FileManager.default.copyItem(at: originalHostURL, to: copyDirectory.appendingPathComponent("host.json"))
        try await engine.close()

        let copiedHost = try CounterHost(url: copyDirectory.appendingPathComponent("host.json"))
        let copied = try await HistoryEngine.open(at: copyStoreURL, scope: scope, workingIdentity: copyID,
                                                   mode: .independentCopy(sourceWorkingIdentity: originalID),
                                                   host: copiedHost)
        XCTAssertTrue(copied.snapshot.canUndo)
        guard case .accepted = await copied.undo() else {
            XCTFail("Copy lost inherited Undo")
            return
        }
        XCTAssertEqual(copiedHost.value, 0)
        try await copied.close()

        let originalHost = try CounterHost(url: originalHostURL)
        let original = try await HistoryEngine.open(at: originalStoreURL, scope: scope,
                                                     workingIdentity: originalID, mode: .existing, host: originalHost)
        XCTAssertEqual(originalHost.value, 5)
        XCTAssertTrue(original.snapshot.canUndo)
        try await original.close()
    }
}
