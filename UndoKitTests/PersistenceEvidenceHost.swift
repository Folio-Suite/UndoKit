// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit

/// A separate durable host store: accepted state and complete receipts share one
/// atomic replacement. Fresh instances load evidence rather than replaying commands.
@MainActor final class PersistenceEvidenceHost: HistoryHost {
    struct Effect: Codable {
        let member: UUID
        let before: Int
        let after: Int
    }
    struct Receipt: Codable {
        let command: UUID
        let scope: UUID
        let generation: UUID
        let sequence: Int64
        let accepted: Bool
        let effects: [Effect]
    }
    private struct State: Codable {
        var value = 0
        var applicationCount = 0
        var deliveryCount = 0
        var receipts: [String: Receipt] = [:]
    }
    let url: URL
    let resourceURL: URL
    let resource: HistoryObjectReference
    private var state: State
    var rejectNext = false
    var hideOutcome = false
    var codecAvailable = true
    var value: Int { state.value }
    var applicationCount: Int { state.applicationCount }
    var deliveryCount: Int { state.deliveryCount }
    var receipts: [Receipt] { Array(state.receipts.values) }

    init(directory: URL, resource: HistoryObjectReference) throws {
        url = directory.appendingPathComponent("host-state.json")
        resourceURL = directory.appendingPathComponent("retained-resource.txt")
        self.resource = resource
        state = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State()
    }

    static func payload(_ value: Int) -> HistoryPayload {
        HistoryPayload(family: "persistence.set", data: Data(String(value).utf8))
    }

    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        if let receipt = state.receipts[delivery.token.command.uuidString] { return outcome(receipt) }
        guard codecAvailable, FileManager.default.fileExists(atPath: resourceURL.path) else {
            return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable))
        }
        var next = state
        var effects: [Effect] = []
        for member in delivery.members {
            guard member.payload.family == "persistence.set", member.payload.version == 1,
                  let text = String(data: member.payload.data, encoding: .utf8), let value = Int(text) else {
                return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable))
            }
            effects.append(Effect(member: member.id, before: next.value, after: value))
            next.value = value
        }
        let accepted = !rejectNext
        rejectNext = false
        if accepted { next.applicationCount += 1 } else { next.value = state.value }
        next.deliveryCount += 1
        let token = delivery.token
        let receipt = Receipt(command: token.command, scope: token.scope, generation: token.generation,
                              sequence: token.sequence, accepted: accepted, effects: effects)
        next.receipts[token.command.uuidString] = receipt
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(next).write(to: url, options: .atomic)
            state = next
            return hideOutcome ? .unresolved : outcome(receipt)
        } catch { return .unresolved }
    }

    func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        guard codecAvailable, FileManager.default.fileExists(atPath: resourceURL.path) else {
            return .failure(HistoryFailure(.compatibility, stage: .reconciliation, disposition: .suspended))
        }
        guard !hideOutcome, let receipt = state.receipts[token.command.uuidString],
              receipt.scope == token.scope, receipt.generation == token.generation,
              receipt.sequence == token.sequence else { return .unresolved }
        return outcome(receipt)
    }

    private func outcome(_ receipt: Receipt) -> HistoryHostOutcome {
        guard receipt.accepted else { return .rejected }
        return .accepted(receipt.effects.map {
            HistoryEffect(memberID: $0.member, undo: Self.payload($0.before), redo: Self.payload($0.after),
                          resources: [resource])
        })
    }
}
