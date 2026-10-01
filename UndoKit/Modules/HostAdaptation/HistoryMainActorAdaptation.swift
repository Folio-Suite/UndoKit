// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

@MainActor extension MainActorHistoryOperationHandler {
    // MARK: - Submission and state conversion

    func submitRegistered(_ command: HistoryTypedCommand<Command>,
                          using registration: HistoryOperationRegistration<Self>,
                          to engine: any HistoryTransactions) async -> HistoryResult {
        do {
            try registration.requireHandler(self, stage: .admission)
            let encoded = try registration.encodeCommand(command)
            return await engine.submit(encoded)
        } catch {
            return .failure(HistoryFailure(.compatibility, stage: .admission, disposition: .usable,
                                          underlyingDescription: String(describing: error)))
        }
    }

    func encodeRegisteredState(_ state: State,
                               using registration: HistoryOperationRegistration<Self>) throws -> HistoryPayload {
        try registration.requireHandler(self, stage: .admission)
        return try registration.encodeStateValue(state)
    }

    func decodeRegisteredState(_ payload: HistoryPayload,
                               using registration: HistoryOperationRegistration<Self>) throws -> State {
        try registration.requireHandler(self, stage: .reconciliation)
        return try registration.decodeStatePayload(payload)
    }

    // MARK: - Host delivery and recovery

    func deliverRegistered(_ delivery: HistoryDelivery,
                           registration: HistoryOperationRegistration<Self>) async -> HistoryHostOutcome {
        let outcome: HistoryTypedOutcome<Effect>
        do {
            try registration.validateDelivery(delivery)
            let context = HistoryOperationContext(token: delivery.token, restorationOrigin: delivery.restorationOrigin)
            switch delivery.kind {
            case .command:
                outcome = await apply(try registration.decodeCommands(delivery.members), context: context)
            case .undo, .redo:
                let effects = try registration.decodeEffects(delivery.members)
                outcome = delivery.kind == .undo
                    ? await undo(effects, context: context)
                    : await redo(effects, context: context)
            }
        } catch {
            return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable,
                                          underlyingDescription: String(describing: error)))
        }
        return registration.encodeOutcome(outcome, expectedMembers: delivery.members.map(\.id))
    }

    func lookupRegistered(_ token: HistoryToken,
                          registration: HistoryOperationRegistration<Self>) async -> HistoryHostOutcome {
        let evidence = await outcome(for: token)
        return registration.encodeOutcome(evidence)
    }
}
