// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Synchronous mechanics run within either supported handler isolation.
extension HistoryOperationRegistration {
    func requireHandler(_ candidate: Handler, stage: HistoryFailureStage) throws {
        guard candidate === handler else {
            throw HistoryFailure(.compatibility, stage: stage, disposition: .usable)
        }
    }

    func encodeCommand(_ command: HistoryTypedCommand<Handler.Command>) throws -> HistoryCommand {
        HistoryCommand(id: command.id, fingerprint: command.fingerprint,
            payload: HistoryPayload(family: identity.operation, version: identity.commandVersion,
                                    data: try encodeEnvelope(command.value, using: commandCodec)),
            restorationOrigin: command.restorationOrigin, presentation: command.presentation,
            expectedGeneration: command.expectedGeneration)
    }

    func encodeStateValue(_ state: Handler.State) throws -> HistoryPayload {
        HistoryPayload(family: identity.operation, version: identity.stateVersion,
                       data: try encodeEnvelope(state, using: stateCodec))
    }

    func decodeStatePayload(_ payload: HistoryPayload) throws -> Handler.State {
        guard payload.family == identity.operation,
              let codec = stateDecoder(for: payload.version) else {
            throw HistoryFailure(.compatibility, stage: .reconciliation, disposition: .usable)
        }
        return try decodeEnvelope(payload.data, using: codec, stage: .reconciliation)
    }

    func validateDelivery(_ delivery: HistoryDelivery) throws {
        guard delivery.members.allSatisfy({ $0.payload.family == identity.operation }) else {
            throw HistoryFailure(.compatibility, stage: .delivery, disposition: .usable)
        }
    }

    func encodeOutcome(_ outcome: HistoryTypedOutcome<Handler.Effect>,
                       expectedMembers: [UUID]? = nil) -> HistoryHostOutcome {
        switch outcome {
        case .rejected: return .rejected
        case .unresolved: return .unresolved
        case .accepted(let effects):
            if let expectedMembers, effects.map(\.memberID) != expectedMembers { return .unresolved }
            do {
                return .accepted(try encodeEffects(effects))
            } catch {
                // Acceptance has already happened. Missing encoded evidence must be reconciled.
                return .unresolved
            }
        }
    }
}
