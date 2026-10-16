// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

extension HistoryApplicationSessionTests {
    func testCloseRequestedDuringHostOpeningNeverRestoresReadiness() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let lease = SessionTestLease()
        let operation = try sessionTestOperation(SessionTestHost())
        lease.waitOnOpen = true
        let opening = Task { @MainActor in
            await owners.open(documentURL: directory, mode: .create, lease: lease) {
                HistorySessionSetup(configuration: applicationConfig(directory), operations: [operation.erased])
            }
        }
        while lease.openingWaiter == nil { await Task.yield() }
        let session = try XCTUnwrap(owners.session(for: directory))
        final class Owner { var phases: [HistorySessionPhase] = [] }
        let observer = Owner()
        let attachment = try session.attach(owner: observer, statusDidChange: { $0.phases.append($1.phase) })
        let closing = Task { @MainActor in await session.close() }
        while session.status.phase != .closing { await Task.yield() }
        lease.finishOpening()
        _ = await opening.value
        await closing.value
        XCTAssertEqual(session.status.phase, .closed)
        XCTAssertFalse(observer.phases.contains(.ready))
        XCTAssertEqual(lease.closes, 1)
        attachment.disconnect()
    }

    func testHostCallbackCannotAwaitItsOwnSubmissionOrCloseItsOwner() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let host = SessionMainHost()
        let operation = try HistoryOperation(
            operation: "session.main", commandCodec: HistoryCodec<Int>.json(),
            effectCodec: HistoryCodec<Int>.json(), handler: host, fingerprint: { try JSONEncoder().encode($0) })
        let session = await owners.open(
            configuration: applicationConfig(directory), lease: SessionTestLease(), operations: [operation.erased])
        let commands = try session.commands(for: operation)
        host.beforeApply = {
            guard case .unexecuted(let failure) = await commands.submit(99) else { return XCTFail("Reentry admitted") }
            XCTAssertEqual(failure.cause, .busy)
            await session.close()
        }
        assertAccepted(await commands.submit(1))
        XCTAssertEqual(session.status.phase, .ready)
        assertAccepted(await commands.submit(2))
        await session.close()
    }

    func testHostLeaseCloseCannotAwaitItsOwnOwnerClosure() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let lease = SessionTestLease()
        let operation = try sessionTestOperation(SessionTestHost())
        let session = await owners.open(
            configuration: applicationConfig(directory), lease: lease, operations: [operation.erased])
        lease.onClose = { [weak session] in await session?.close() }
        await session.close()
        XCTAssertEqual(session.status.phase, .closed)
        XCTAssertEqual(lease.closes, 1)
    }

    func testCloseAllFencesNewAcquisitionsAndRefusalsDoNotPolluteDocumentLookup() async throws {
        let directory = try sessionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = HistorySessions()
        let lease = SessionTestLease()
        let operation = try sessionTestOperation(SessionTestHost())
        let session = await owners.open(
            configuration: applicationConfig(directory), lease: lease, operations: [operation.erased])
        let closingEntered = expectation(description: "Host close entered")
        var releaseClose: CheckedContinuation<Void, Never>?
        lease.onClose = {
            closingEntered.fulfill()
            await withCheckedContinuation { releaseClose = $0 }
            await owners.closeAll()  // Reentry must not wait on the enclosing closeAll.
        }
        let closing = Task { @MainActor in await owners.closeAll() }
        await fulfillment(of: [closingEntered])
        let incomingLease = SessionTestLease()
        let nextConfig = applicationConfig(directory.appendingPathComponent("Other"))
        let refusal = await owners.open(configuration: nextConfig, lease: incomingLease, operations: [operation.erased])
        XCTAssertEqual(refusal.status.issue?.cause, .busy)
        XCTAssertEqual(incomingLease.opens, 0)
        XCTAssertIdentical(owners.session(for: session.documentURL), session)
        XCTAssertNil(owners.session(for: refusal.documentURL))
        releaseClose?.resume()
        await closing.value
        XCTAssertEqual(session.status.phase, .closed)
        await refusal.close()
    }
}
