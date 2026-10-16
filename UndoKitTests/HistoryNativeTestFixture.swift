// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import UndoKit

@MainActor final class NativeFieldTestHost: MainActorHistoryOperationHandler, HistoryHostLease {
    typealias Command = String
    typealias Effect = String
    typealias State = String
    struct Evidence: Codable {
        let member: UUID
        let undo: String
        let redo: String
    }
    struct Receipt: Codable {
        let accepted: Bool
        let evidence: [Evidence]
    }
    struct Stored: Codable {
        var value = ""
        var revision = 0
        var receipts: [String: Receipt] = [:]
    }
    let directory: URL
    let scope = UUID(), working = UUID()
    var state = Stored()
    var loseNextReply = false
    var rejectNext = false
    var failReads = false
    var closed = false
    var failClose = false
    var delayClose = false
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private var closeStarted: CheckedContinuation<Void, Never>?
    var delayed = false
    private var deliveryWaiter: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    var snapshot: HistoryFieldSnapshot<String> {
        get throws {
            if failReads { throw CocoaError(.fileReadNoPermission) }
            return HistoryFieldSnapshot(value: state.value, revision: Data(String(state.revision).utf8))
        }
    }
    init(directory: URL) { self.directory = directory }
    func open(_ mode: HistoryOpenMode) async throws {
        let file = directory.appendingPathComponent("Domain.json")
        if mode == .create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
        } else {
            state = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
        }
        closed = false
    }
    func close() async throws {
        if failClose { throw CocoaError(.fileWriteNoPermission) }
        if delayClose {
            await withCheckedContinuation {
                closeWaiter = $0
                closeStarted?.resume()
                closeStarted = nil
            }
        }
        closed = true
    }
    func waitUntilClose() async {
        if closeWaiter != nil { return }
        await withCheckedContinuation { closeStarted = $0 }
    }
    func resumeClose() {
        delayClose = false
        closeWaiter?.resume()
        closeWaiter = nil
    }
    func operation() throws -> HistoryOperation<String> {
        try HistoryOperation(
            operation: "native-test.field", commandCodec: .json(), effectCodec: .json(), handler: self,
            fingerprint: { try JSONEncoder().encode($0) })
    }
    func apply(_ commands: [(UUID, String)], context: HistoryOperationContext) async -> HistoryTypedOutcome<String> {
        if delayed {
            await withCheckedContinuation {
                deliveryWaiter = $0
                startedWaiter?.resume()
                startedWaiter = nil
            }
        }
        return execute(commands, context: context)
    }
    func undo(_ effects: [(UUID, String)], context: HistoryOperationContext) async -> HistoryTypedOutcome<String> {
        execute(effects, context: context)
    }
    func redo(_ effects: [(UUID, String)], context: HistoryOperationContext) async -> HistoryTypedOutcome<String> {
        execute(effects, context: context)
    }
    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<String> {
        guard let receipt = state.receipts[key(token)] else { return .rejected }
        return outcome(receipt)
    }
    private func execute(_ values: [(UUID, String)], context: HistoryOperationContext) -> HistoryTypedOutcome<String> {
        if let receipt = state.receipts[key(context.token)] { return outcome(receipt) }
        var candidate = state
        var evidence: [Evidence] = []
        let accepted = !rejectNext
        rejectNext = false
        if accepted {
            for (member, value) in values {
                evidence.append(Evidence(member: member, undo: candidate.value, redo: value))
                candidate.value = value
            }
            candidate.revision += 1
        }
        let receipt = Receipt(accepted: accepted, evidence: evidence)
        candidate.receipts[key(context.token)] = receipt
        do {
            try JSONEncoder().encode(candidate).write(
                to: directory.appendingPathComponent("Domain.json"), options: .atomic)
            state = candidate
            if loseNextReply {
                loseNextReply = false
                return .unresolved
            }
            return outcome(receipt)
        } catch { return .unresolved }
    }
    private func key(_ token: HistoryToken) -> String {
        "\(token.scope):\(token.generation):\(token.sequence):\(token.command)"
    }
    private func outcome(_ receipt: Receipt) -> HistoryTypedOutcome<String> {
        receipt.accepted
            ? .accepted(receipt.evidence.map { HistoryTypedEffect(memberID: $0.member, undo: $0.undo, redo: $0.redo) })
            : .rejected
    }
    func waitUntilDelivery() async {
        if deliveryWaiter != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func resume() {
        delayed = false
        deliveryWaiter?.resume()
        deliveryWaiter = nil
    }
}

@MainActor final class NativeFieldTestAdapter: HistoryNativePlatformAdapter {
    let attachmentID: UUID
    let control = UUID()
    let field: String
    var value = ""
    var composing = false
    var available = true
    let undoManager = UndoManager()
    var retirements: [UUID] = []
    var detached = false
    unowned let session: HistorySession
    init(attachment: HistoryAttachment, field: String) {
        attachmentID = attachment.id
        session = attachment.session
        self.field = field
    }
    func change(_ value: String, composing: Bool = false) throws {
        guard
            session.nativeCoordinator.beginChange(
                attachment: attachmentID, control: control, field: field, composing: self.composing)
        else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        self.value = value
        self.composing = composing
        session.nativeCoordinator.changed(
            attachment: attachmentID, control: control, field: field, value: value, composing: composing)
    }
    func capture(control: UUID) -> (value: String, composing: Bool)? {
        control == self.control ? (value, composing) : nil
    }
    func render(field: String, value: String) { if self.field == field { self.value = value } }
    func publishAvailability() {}
    func liveManager(control: UUID) -> UndoManager? { control == self.control ? undoManager : nil }
    func retire(transaction: UUID) {
        retirements.append(transaction)
        undoManager.removeAllActions()
    }
    func detach() { detached = true }
}

@MainActor struct NativeFieldTestFixture {
    let root: URL
    let host: NativeFieldTestHost
    let sessions: HistorySessions
    let session: HistorySession
    let commands: HistoryCommands<String>
    let field: HistoryField<String>
    static func open(limits: HistoryLimits = HistoryLimits()) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = NativeFieldTestHost(directory: root)
        let sessions = HistorySessions()
        let operation = try host.operation()
        let configuration = HistorySessionConfiguration(
            historyURL: root.appendingPathComponent("History.sqlite"),
            scope: host.scope, workingIdentity: host.working, mode: .create, limits: limits)
        let session = await sessions.open(configuration: configuration, lease: host, operations: [operation.erased])
        XCTAssertEqual(session.status.phase, .ready)
        let commands = try session.commands(for: operation)
        let field = HistoryField<String>(
            id: "title", mappingID: "title.replace", codec: .json(), commands: commands,
            read: { try host.snapshot }, makeCommands: { base, proposed in proposed == base.value ? [] : [proposed] })
        return Self(root: root, host: host, sessions: sessions, session: session, commands: commands, field: field)
    }
    func reopen() async throws -> Self {
        let operation = try host.operation()
        let configuration = HistorySessionConfiguration(
            historyURL: root.appendingPathComponent("History.sqlite"),
            scope: host.scope, workingIdentity: host.working, mode: .existing)
        let reopened = await sessions.open(configuration: configuration, lease: host, operations: [operation.erased])
        let commands = try reopened.commands(for: operation)
        let field = HistoryField<String>(
            id: "title", mappingID: "title.replace", codec: .json(), commands: commands,
            read: { try host.snapshot }, makeCommands: { base, proposed in proposed == base.value ? [] : [proposed] })
        return Self(root: root, host: host, sessions: sessions, session: reopened, commands: commands, field: field)
    }
    func adapter(owner: AnyObject = NSObject()) async throws -> (HistoryAttachment, NativeFieldTestAdapter) {
        let attachment = try session.attach(owner: owner)
        let adapter = NativeFieldTestAdapter(attachment: attachment, field: field.id)
        adapter.value = try await session.nativeCoordinator.register(field)
        attachment.platform = adapter
        session.nativeCoordinator.register(adapter)
        session.nativeCoordinator.restoreTransaction(
            attachment: attachment.id, control: adapter.control, field: field.id)
        return (attachment, adapter)
    }
    func close() async {
        await session.close()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor final class NativeFieldReadGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation {
            waiter = $0
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if waiter != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resume() {
        waiter?.resume()
        waiter = nil
    }
}
