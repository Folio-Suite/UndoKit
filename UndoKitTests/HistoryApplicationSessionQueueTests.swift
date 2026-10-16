// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

extension HistoryApplicationSessionTests {
    func testDelayedBackgroundEncodingPreservesReservationOrder() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let fastEncoded = DispatchSemaphore(value: 0)
        let slowCodec = HistoryCodec<Int>(
            identifier: "slow-int",
            encode: { value in
                started.signal()
                release.wait()
                return try JSONEncoder().encode(value)
            }, decode: { try JSONDecoder().decode(Int.self, from: $0) })
        let fastCodec = HistoryCodec<Int>(
            identifier: "fast-int",
            encode: { value in
                fastEncoded.signal()
                return try JSONEncoder().encode(value)
            }, decode: { try JSONDecoder().decode(Int.self, from: $0) })
        let log = SessionDeliveryLog()
        let owners = HistorySessions()
        let slow = try sessionTestOperation(SessionTestHost(log: log), codec: slowCodec)
        let fast = try HistoryOperation(
            operation: "session.fast", commandCodec: fastCodec,
            effectCodec: HistoryCodec<Int>.json(), handler: SessionMainHost(log: log),
            fingerprint: { try JSONEncoder().encode($0) })
        let session = await owners.open(
            configuration: applicationConfig(directory), lease: SessionTestLease(),
            operations: [slow.erased, fast.erased])
        let slowHandle = try session.commands(for: slow)
        let fastHandle = try session.commands(for: fast)
        let first = Task { @MainActor in await slowHandle.submit(1) }
        await Task.detached { waitForSessionSemaphore(started) }.value
        let second = Task { @MainActor in await fastHandle.submit(2) }
        await Task.detached { waitForSessionSemaphore(fastEncoded) }.value
        XCTAssertTrue(log.values.isEmpty)
        XCTAssertEqual(session.status.phase, .busy)
        release.signal()
        assertAccepted(await first.value)
        assertAccepted(await second.value)
        XCTAssertEqual(log.values, [1, 2])
        await session.close()
    }

    func testCancellingEncodingCompletesBeforeEncoderReturnsAndNeverDeliversLateValue() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let codec = HistoryCodec<Int>(
            identifier: "cancellable-int",
            encode: { value in
                if value == 1 {
                    started.signal()
                    release.wait()
                }
                return try JSONEncoder().encode(value)
            }, decode: { try JSONDecoder().decode(Int.self, from: $0) })
        let owners = HistorySessions()
        let host = SessionTestHost()
        let operation = try sessionTestOperation(host, codec: codec)
        let session = await owners.open(
            configuration: applicationConfig(directory), lease: SessionTestLease(), operations: [operation.erased])
        let commands = try session.commands(for: operation)
        let first = Task { @MainActor in await commands.submit(1) }
        await Task.detached { waitForSessionSemaphore(started) }.value
        first.cancel()
        guard case .unexecuted(let failure) = await first.value else {
            release.signal()
            XCTFail("Cancelled encoding did not terminalize")
            return
        }
        XCTAssertEqual(failure.cause, .cancelled)
        release.signal()
        assertAccepted(await commands.submit(2))
        let delivered = await host.delivered()
        XCTAssertEqual(delivered, [2])
        await session.close()
    }

    func testUncertaintyCompletesQueuedIntentUnexecutedAndReconciliationDoesNotReplayIt() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let host = SessionTestHost()
        let operation = try sessionTestOperation(host)
        let session = await owners.open(
            configuration: applicationConfig(directory), lease: SessionTestLease(), operations: [operation.erased])
        let commands = try session.commands(for: operation)
        await host.pauseNextAndLoseReply()
        let first = Task { @MainActor in await commands.submit(1) }
        await host.waitUntilPaused()
        let second = Task { @MainActor in await commands.submit(2) }
        await Task.yield()
        await host.resume()
        guard case .unresolved = await first.value else { XCTFail("Delivered uncertainty lost")
return }
        guard case .unexecuted(let failure) = await second.value else {
            XCTFail("Queued intent was not explicitly unexecuted")
            return
        }
        XCTAssertEqual(failure.disposition, .suspended)
        _ = await session.reconcile()
        let afterRecovery = await host.delivered()
        XCTAssertEqual(afterRecovery, [1])
        assertAccepted(await commands.submit(3))
        let afterFresh = await host.delivered()
        XCTAssertEqual(afterFresh, [1, 3])
        await session.close()
    }

    func testActorLocalMutableIntentFreezesBeforeSuspensionAndRejectsDifferentHandler() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frozen = DispatchSemaphore(value: 0)
        let codec = HistoryCodec<SessionLocalBox>(
            identifier: "local.box",
            encode: { box in
                let encoded = Data(String(box.value).utf8)
                frozen.signal()
                return encoded
            },
            decode: { bytes in
                guard let text = String(bytes: bytes, encoding: .utf8), let value = Int(text) else {
                    throw CocoaError(.coderReadCorrupt)
                }
                return SessionLocalBox(value)
            })
        let host = SessionLocalHost()
        let operation = try HistoryLocalOperation(
            operation: "local.box", commandCodec: codec,
            effectCodec: codec, handler: host,
            fingerprint: { Data($0.map { String($0.value) }.joined(separator: ",").utf8) })
        let owners = HistorySessions()
        let session = await owners.open(
            configuration: applicationConfig(directory), lease: SessionTestLease(), operations: [operation.erased])
        let commands = try session.localCommands(for: operation)
        let submission = Task { await host.send(commands) }
        await Task.detached { waitForSessionSemaphore(frozen) }.value
        await host.mutate()
        assertAccepted(await submission.value)
        let delivered = await host.delivered()
        XCTAssertEqual(delivered, [4])
        let differentHost = SessionLocalHost()
        guard case .unexecuted(let conflict) = await differentHost.send(commands) else {
            XCTFail("Different handler used a bound local handle")
            return
        }
        XCTAssertEqual(conflict.cause, .identityConflict)
        _ = try session.advanced.clearHistory(adopting: HistoryPayload(family: "baseline", data: Data([0])))
        guard case .unexecuted(let retired) = await host.send(commands) else {
            XCTFail("Retired local handle executed")
            return
        }
        XCTAssertEqual(retired.cause, .identityConflict)
        await session.close()
    }
}
