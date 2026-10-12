// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

#if DEBUG
@MainActor final class HistoryDebugFailureInjectionTests: XCTestCase {
    /// Public seam: a host can submit to another scope without inheriting this
    /// controlled Command's accepted-finalization failure.
    func testInjectedFailureDoesNotPoisonIndependentOwnerWithSameScopeAndCommandIDs() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let peerHost = DebugInjectionHost()
        let sharedScope = UUID()
        let peer = try await HistoryEngine.open(at: directory.appendingPathComponent("Peer.sqlite"),
            scope: sharedScope, workingIdentity: UUID(), mode: .create, host: peerHost)
        let primaryHost = DebugInjectionHost()
        primaryHost.peer = peer
        let command = DebugInjectionHost.command("primary")
        primaryHost.peerCommandID = command.id
        let primary = try await HistoryEngine.open(at: directory.appendingPathComponent("Primary.sqlite"),
            scope: sharedScope, workingIdentity: UUID(), mode: .create, host: primaryHost)
        let result = await primary.submitWithInjectedFinalizationFailure(command)
        guard case .failure(let failure) = result else { return XCTFail("Selected finalization did not fail") }
        XCTAssertEqual(failure.cause, .storage)
        XCTAssertEqual(failure.stage, .finalization)
        XCTAssertTrue(primary.snapshot.isSuspended)
        guard case .accepted = primaryHost.peerResult else { return XCTFail("Unrelated Command inherited failure") }
        XCTAssertFalse(peer.snapshot.isSuspended)
        XCTAssertTrue(peer.snapshot.canUndo)
        XCTAssertEqual(peerHost.value, "peer")
        XCTAssertEqual(try peer.historyPage(limit: 10).count, 1)
        try await primary.close(); try await peer.close()
    }

    func testInjectionRefusesBusyEngineWithoutAffectingOrdinaryDelivery() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = DebugInjectionHost(); host.delay = true
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host)
        let ordinary = Task { await engine.submit(DebugInjectionHost.command("ordinary")) }
        await host.waitUntilDeliveryStarted()
        defer { host.releaseDelivery() }
        let refusal = await engine.submitWithInjectedFinalizationFailure(DebugInjectionHost.command("injected"))
        host.releaseDelivery()
        let ordinaryResult = await ordinary.value
        let wasSuspended = engine.snapshot.isSuspended
        try await engine.close()
        guard case .failure(let failure) = refusal else { return XCTFail("Busy injection was admitted") }
        XCTAssertEqual(failure.cause, .busy)
        guard case .accepted = ordinaryResult else { return XCTFail("Ordinary delivery was poisoned") }
        XCTAssertEqual(host.value, "ordinary")
        XCTAssertFalse(wasSuspended)
    }
}

@MainActor private final class DebugInjectionHost: HistoryHost {
    var value = ""
    var peer: HistoryEngine?
    var peerResult: HistoryResult?
    var peerCommandID = UUID()
    var delay = false
    var waiting: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    var outcomes: [HistoryToken: HistoryHostOutcome] = [:]
    static func command(_ value: String, id: UUID = UUID()) -> HistoryCommand {
        HistoryCommand(id: id, fingerprint: Data(value.utf8), payload: HistoryPayload(family: "debug-injection", data: Data(value.utf8)))
    }
    func waitUntilDeliveryStarted() async {
        if waiting != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseDelivery() { waiting?.resume(); waiting = nil }
    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        if let prior = outcomes[delivery.token] { return prior }
        if delay {
            await withCheckedContinuation { waiting = $0; started?.resume(); started = nil }
        }
        if let peer { peerResult = await peer.submit(Self.command("peer", id: peerCommandID)) }
        let previous = value
        value = String(decoding: delivery.members[0].payload.data, as: UTF8.self)
        let outcome = HistoryHostOutcome.accepted([
            HistoryEffect(memberID: delivery.members[0].id,
                undo: HistoryPayload(family: "debug-injection", data: Data(previous.utf8)),
                redo: delivery.members[0].payload)
        ])
        outcomes[delivery.token] = outcome
        return outcome
    }
    func outcome(for token: HistoryToken) async -> HistoryHostOutcome { outcomes[token] ?? .rejected }
}
#endif
