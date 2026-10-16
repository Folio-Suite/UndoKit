// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor private final class ActivityAdmissionHost: HistoryHost {
    let host: CounterHost
    let gate = NativeFieldReadGate()
    private var pause = true

    init(_ host: CounterHost) { self.host = host }

    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        if pause {
            pause = false
            await gate.pause()
        }
        return await host.deliver(delivery)
    }

    func outcome(for token: HistoryToken) async -> HistoryHostOutcome { await host.outcome(for: token) }
}

@MainActor final class HistoryActivityAdmissionTests: XCTestCase {
    func testMaintenanceDrainsAdmittedCommandsAcrossIndependentScopes() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
            workingIdentity: UUID(), mode: .create)
        let one = ActivityAdmissionHost(try CounterHost(url: directory.appendingPathComponent("One.json")))
        let two = ActivityAdmissionHost(try CounterHost(url: directory.appendingPathComponent("Two.json")))
        let firstScope = UUID(), secondScope = UUID()
        let first = try await store.openScope(firstScope, mode: .create, host: one)
        let second = try await store.openScope(secondScope, mode: .create, host: two)
        let idle = try await store.openScope(UUID(), mode: .create,
            host: CounterHost(url: directory.appendingPathComponent("Idle.json")))
        defer { one.gate.resume(); two.gate.resume() }
        let firstCommand = Task { await first.submit(HistoryCommand(fingerprint: Data([1]), payload: payload(1))) }
        await one.gate.waitUntilStarted()
        let secondCommand = Task { await second.submit(HistoryCommand(fingerprint: Data([2]), payload: payload(2))) }
        await two.gate.waitUntilStarted()
        let queued = expectation(description: "Second first-scope Command admitted")
        let queuedCommand = Task {
            queued.fulfill()
            return await first.submit(HistoryCommand(fingerprint: Data([3]), payload: payload(3)))
        }
        await fulfillment(of: [queued], timeout: 2)
        let started = expectation(description: "Store maintenance admitted")
        var captured = false
        let destination = directory.appendingPathComponent("Copy.sqlite")
        let copy = Task {
            started.fulfill()
            try await store.withCoordinatedCopy(to: destination) { _ in captured = true }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(captured)
        guard case .failure(let failure) = await idle.submit(
            HistoryCommand(fingerprint: Data([4]), payload: payload(4))) else {
            XCTFail("Store maintenance admitted a new Command")
            return
        }
        XCTAssertEqual(failure.cause, .busy)
        one.gate.resume()
        assertAccepted(await firstCommand.value, "Maintenance rejected an already admitted Command")
        assertAccepted(await queuedCommand.value, "Maintenance rejected an already admitted queued Command")
        XCTAssertFalse(captured, "Another scope still owns an active host callback")
        two.gate.resume()
        assertAccepted(await secondCommand.value, "Second scope failed")
        try await copy.value
        XCTAssertTrue(captured)
        XCTAssertEqual(one.host.value, 3)
        XCTAssertEqual(two.host.value, 2)
        XCTAssertEqual(one.host.deliveries, 2)
        XCTAssertEqual(two.host.deliveries, 1)
        try await assertCommittedCopy(of: store, at: destination, scopeCounts: [firstScope: 2, secondScope: 1])
    }

    func testCancellingMaintenanceReleasesItsWaiterWhileHostRemainsActive() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
            workingIdentity: UUID(), mode: .create)
        let host = ActivityAdmissionHost(try CounterHost(url: directory.appendingPathComponent("One.json")))
        let active = try await store.openScope(UUID(), mode: .create, host: host)
        let otherHost = try CounterHost(url: directory.appendingPathComponent("Other.json"))
        let other = try await store.openScope(UUID(), mode: .create, host: otherHost)
        let command = Task { await active.submit(HistoryCommand(fingerprint: Data([1]), payload: payload(1))) }
        await host.gate.waitUntilStarted()
        let started = expectation(description: "Maintenance waiting for the active scope")
        let destination = directory.appendingPathComponent("Cancelled.sqlite")
        let copying = Task {
            started.fulfill()
            try await store.copy(to: destination)
        }
        await fulfillment(of: [started], timeout: 2)
        copying.cancel()
        do {
            try await copying.value
            XCTFail("Cancelled maintenance succeeded")
        } catch let failure as HistoryFailure { XCTAssertEqual(failure.cause, .cancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let otherResult = await other.submit(HistoryCommand(fingerprint: Data([2]), payload: payload(2)))
        assertAccepted(otherResult, "Cancelled maintenance retained its store fence")
        host.gate.resume()
        assertAccepted(await command.value, "Cancellation lost admitted host work")
        try await store.copy(to: directory.appendingPathComponent("Completed.sqlite"))
        XCTAssertEqual(host.host.deliveries, 1)
        try await store.close()
    }

    private func assertAccepted(
        _ result: HistoryResult, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .accepted = result else {
            XCTFail(message, file: file, line: line)
            return
        }
    }

    private func assertCommittedCopy(
        of store: HistoryStore, at destination: URL, scopeCounts: [UUID: Int]
    ) async throws {
        try await store.close()
        let reader = try await HistoryStore.open(at: destination, workingIdentity: store.workingIdentity,
            mode: .existing, access: .readOnly)
        for (scope, count) in scopeCounts {
            XCTAssertEqual(try reader.historyPage(scope: scope, limit: 10).count, count)
        }
        try await reader.close()
    }

}
