// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

func waitForSessionSemaphore(_ semaphore: DispatchSemaphore) { semaphore.wait() }

@MainActor final class SessionTestLease: HistoryHostLease {
    var opens = 0
    var closes = 0
    var waitOnOpen = false
    var openingWaiter: CheckedContinuation<Void, Never>?
    var onClose: (@MainActor () async throws -> Void)?
    func open(_ mode: HistoryOpenMode) async throws {
        opens += 1
        if waitOnOpen { await withCheckedContinuation { openingWaiter = $0 } }
    }
    func close() async throws {
        try await onClose?()
        closes += 1
    }
    func finishOpening() {
        waitOnOpen = false
        openingWaiter?.resume()
        openingWaiter = nil
    }
}

@MainActor final class SessionDeliveryLog {
    var values: [Int] = []
}

actor SessionTestHost: HistoryOperationHandler {
    typealias Command = Int
    typealias Effect = Int
    var receipts: [HistoryToken: HistoryTypedOutcome<Int>] = [:]
    var values: [Int] = []
    var pause = false
    var loseReply = false
    var paused: CheckedContinuation<Void, Never>?
    var reachedPause: CheckedContinuation<Void, Never>?
    var isPaused = false
    let log: SessionDeliveryLog?
    init(log: SessionDeliveryLog? = nil) { self.log = log }
    func apply(_ commands: [(UUID, Int)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Int> {
        values += commands.map(\.1)
        if let log { await MainActor.run { log.values += commands.map(\.1) } }
        let accepted = HistoryTypedOutcome.accepted(
            commands.map { HistoryTypedEffect(memberID: $0.0, undo: -$0.1, redo: $0.1) })
        receipts[context.token] = accepted
        if pause {
            pause = false
            isPaused = true
            reachedPause?.resume()
            reachedPause = nil
            await withCheckedContinuation { paused = $0 }
            isPaused = false
        }
        if loseReply {
            loseReply = false
            return .unresolved
        }
        return accepted
    }
    func undo(_ effects: [(UUID, Int)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Int> {
        await apply(effects, context: context)
    }
    func redo(_ effects: [(UUID, Int)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Int> {
        await apply(effects, context: context)
    }
    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<Int> { receipts[token] ?? .unresolved }
    func delivered() -> [Int] { values }
    func pauseNextAndLoseReply() {
        pause = true
        loseReply = true
    }
    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { reachedPause = $0 }
    }
    func resume() {
        paused?.resume()
        paused = nil
    }
}

@MainActor final class SessionMainHost: MainActorHistoryOperationHandler {
    typealias Command = Int
    typealias Effect = Int
    let log: SessionDeliveryLog?
    var beforeApply: (() async -> Void)?
    init(log: SessionDeliveryLog? = nil) { self.log = log }
    func apply(_ commands: [(UUID, Int)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Int> {
        let callback = beforeApply
        beforeApply = nil
        await callback?()
        log?.values += commands.map(\.1)
        return .accepted(commands.map { HistoryTypedEffect(memberID: $0.0, undo: -$0.1, redo: $0.1) })
    }
    func undo(_ effects: [(UUID, Int)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Int> {
        await apply(effects, context: context)
    }
    func redo(_ effects: [(UUID, Int)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Int> {
        await apply(effects, context: context)
    }
    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<Int> { .unresolved }
}

final class SessionLocalBox {
    var value: Int
    init(_ value: Int) { self.value = value }
}
actor SessionLocalHost: HistoryOperationHandler {
    typealias Command = SessionLocalBox
    typealias Effect = SessionLocalBox
    private let retained = SessionLocalBox(4)
    private var values: [Int] = []
    func send(_ commands: HistoryLocalCommands<SessionLocalHost>) async -> HistorySubmissionResult {
        await submit(retained, using: commands)
    }
    func mutate() { retained.value = 99 }
    func delivered() -> [Int] { values }
    func apply(_ commands: [(UUID, SessionLocalBox)], context: HistoryOperationContext) async -> HistoryTypedOutcome<
        SessionLocalBox
    > {
        values += commands.map { $0.1.value }
        return .accepted(
            commands.map {
                HistoryTypedEffect(
                    memberID: $0.0,
                    undo: SessionLocalBox(-$0.1.value), redo: SessionLocalBox($0.1.value))
            })
    }
    func undo(_ effects: [(UUID, SessionLocalBox)], context: HistoryOperationContext) async -> HistoryTypedOutcome<
        SessionLocalBox
    > { await apply(effects, context: context) }
    func redo(_ effects: [(UUID, SessionLocalBox)], context: HistoryOperationContext) async -> HistoryTypedOutcome<
        SessionLocalBox
    > { await apply(effects, context: context) }
    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<SessionLocalBox> { .unresolved }
}

@MainActor func sessionTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryApplicationSession-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor func sessionTestOperation(
    _ host: SessionTestHost, family: String = "session.integer",
    codec: HistoryCodec<Int> = .json()
) throws -> HistoryOperation<Int> {
    try HistoryOperation(
        operation: family, commandCodec: codec,
        effectCodec: .json(), handler: host, fingerprint: { try JSONEncoder().encode($0) })
}

@MainActor func applicationConfig(
    _ directory: URL, scope: UUID = UUID(), working: UUID = UUID(),
    mode: HistoryOpenMode = .create
) -> HistorySessionConfiguration {
    HistorySessionConfiguration(
        historyURL: directory.appendingPathComponent("History.sqlite"),
        scope: scope, workingIdentity: working, mode: mode)
}

@MainActor func assertAccepted(_ result: HistorySubmissionResult, file: StaticString = #filePath, line: UInt = #line) {
    guard case .accepted = result else {
        XCTFail("Expected accepted; got \(result)", file: file, line: line)
        return
    }
}
