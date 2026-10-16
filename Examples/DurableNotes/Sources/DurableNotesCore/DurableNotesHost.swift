// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit

/// This bounded example has one writer and one atomic JSON file per document.
/// Domain state and authoritative token receipts always commit in the same rename.
actor DurableNotesHost: HistoryOperationHandler {
    typealias Command = NoteChange
    typealias Effect = NoteChange
    struct StoredEffect: Codable {
        let member: UUID
        let undo: NoteChange
        let redo: NoteChange
    }
    struct Receipt: Codable {
        let accepted: Bool
        let effects: [StoredEffect]
    }
    struct State: Codable {
        var scope = UUID()
        var workingIdentity = UUID()
        var note = Note()
        var receipts: [String: Receipt] = [:]
        var applicationCount = 0
    }
    private let url: URL
    private var state: State
    private var deliveryCount = 0
    private var rejectNext = false
    private var delayNext = false
    private var delayed: CheckedContinuation<Void, Never>?
    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }

    init(url: URL, createIfMissing: Bool = true) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        } else {
            guard createIfMissing else { throw HistoryFailure(.missingHistory, stage: .admission, disposition: .suspended) }
            state = State()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: Self.writeOptions)
        }
    }
    func identity() -> (scope: UUID, working: UUID) { (state.scope, state.workingIdentity) }
    func read() -> NotesReadout {
        NotesReadout(note: state.note, receiptCount: state.receipts.count, applicationCount: state.applicationCount, deliveryCount: deliveryCount)
    }
    func rejectNextDelivery() { rejectNext = true }
    func delayNextDelivery() { delayNext = true }
    func resumeDelivery() { delayed?.resume(); delayed = nil }
    func isDeliveryDelayed() -> Bool { delayed != nil }

    func apply(_ commands: [(UUID, NoteChange)], context: HistoryOperationContext) async -> HistoryTypedOutcome<NoteChange> {
        await execute(commands, token: context.token)
    }
    func undo(_ effects: [(UUID, NoteChange)], context: HistoryOperationContext) async -> HistoryTypedOutcome<NoteChange> {
        await execute(effects, token: context.token)
    }
    func redo(_ effects: [(UUID, NoteChange)], context: HistoryOperationContext) async -> HistoryTypedOutcome<NoteChange> {
        await execute(effects, token: context.token)
    }
    private func execute(_ changes: [(UUID, NoteChange)], token: HistoryToken) async -> HistoryTypedOutcome<NoteChange> {
        deliveryCount += 1
        let key = Self.key(token)
        if let receipt = state.receipts[key] { return Self.outcome(receipt) }
        if delayNext {
            delayNext = false
            await withCheckedContinuation { delayed = $0 }
        }
        var next = state
        var effects: [StoredEffect] = []
        var accepted = !rejectNext
        rejectNext = false
        do {
            for (memberID, change) in changes {
                let prior = change.field == .title ? next.note.title : next.note.body
                guard prior == change.expected, change.replacement.utf8.count <= 32_768 else {
                    accepted = false
                    break
                }
                if change.field == .title { next.note.title = change.replacement }
                else { next.note.body = change.replacement }
                effects.append(StoredEffect(member: memberID,
                    undo: NoteChange(field: change.field, expected: change.replacement, replacement: prior), redo: change))
            }
            if !accepted { next = state; effects = [] }
            let receipt = Receipt(accepted: accepted, effects: effects)
            next.receipts[key] = receipt
            if accepted { next.applicationCount += 1 }
            try JSONEncoder().encode(next).write(to: url, options: Self.writeOptions)
            state = next
            return Self.outcome(receipt)
        } catch { return .unresolved }
    }

    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<NoteChange> {
        // Reload after an uncertain write: a rename may have succeeded before an error.
        // An intact file with no token proves this single writer committed no effect.
        do {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            return state.receipts[Self.key(token)].map(Self.outcome) ?? .rejected
        } catch { return .unresolved }
    }
    private static func key(_ token: HistoryToken) -> String {
        "\(token.scope):\(token.generation):\(token.sequence):\(token.command)"
    }
    private static func outcome(_ receipt: Receipt) -> HistoryTypedOutcome<NoteChange> {
        guard receipt.accepted else { return .rejected }
        return .accepted(receipt.effects.map {
            HistoryTypedEffect(memberID: $0.member, undo: $0.undo, redo: $0.redo)
        })
    }
}
