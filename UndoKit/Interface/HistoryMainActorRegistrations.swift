// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

@MainActor public extension MainActorHistoryOperationHandler {
    func submit(_ command: HistoryTypedCommand<Command>,
                using registration: HistoryOperationRegistration<Self>,
                to engine: HistoryEngine) async -> HistoryResult {
        guard registration.identity.commandVersion > 0,
              registration.commandCodec.identifier == registration.identity.commandCodec,
              registration.commandCodec.configuration == registration.identity.commandCodecConfiguration else {
            return .failure(HistoryFailure(.compatibility, stage: .admission, disposition: .usable))
        }
        do {
            let envelope = HistoryCodecEnvelope(codec: registration.identity.commandCodec,
                                                configuration: registration.identity.commandCodecConfiguration,
                                                bytes: try registration.commandCodec.encode(command.value))
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return await engine.submit(HistoryCommand(
                id: command.id, fingerprint: command.fingerprint,
                payload: HistoryPayload(family: registration.identity.operation,
                                        version: registration.identity.commandVersion,
                                        data: try encoder.encode(envelope))
            ))
        } catch {
            return .failure(HistoryFailure(.compatibility, stage: .admission, disposition: .usable,
                                          underlyingDescription: String(describing: error)))
        }
    }

    func encodeState(_ state: State, using registration: HistoryOperationRegistration<Self>) throws -> HistoryPayload {
        guard registration.stateCodec.identifier == registration.identity.stateCodec,
              registration.stateCodec.configuration == registration.identity.stateCodecConfiguration else {
            throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
        }
        let envelope = HistoryCodecEnvelope(codec: registration.identity.stateCodec,
                                            configuration: registration.identity.stateCodecConfiguration,
                                            bytes: try registration.stateCodec.encode(state))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return HistoryPayload(family: registration.identity.operation,
                              version: registration.identity.stateVersion,
                              data: try encoder.encode(envelope))
    }

    func decodeState(_ payload: HistoryPayload, using registration: HistoryOperationRegistration<Self>) throws -> State {
        guard payload.family == registration.identity.operation,
              payload.version == registration.identity.stateVersion,
              registration.stateCodec.identifier == registration.identity.stateCodec,
              registration.stateCodec.configuration == registration.identity.stateCodecConfiguration else {
            throw HistoryFailure(.compatibility, stage: .reconciliation, disposition: .usable)
        }
        let envelope = try PropertyListDecoder().decode(HistoryCodecEnvelope.self, from: payload.data)
        guard envelope.codec == registration.identity.stateCodec,
              envelope.configuration == registration.identity.stateCodecConfiguration else {
            throw HistoryFailure(.compatibility, stage: .reconciliation, disposition: .usable)
        }
        return try registration.stateCodec.decode(envelope.bytes)
    }

    internal func deliver(
        _ delivery: HistoryDelivery,
        registration: HistoryOperationRegistration<Self>
    ) async -> HistoryHostOutcome {
        guard registration.identity.commandVersion > 0, registration.identity.effectVersion > 0,
              registration.commandCodec.identifier == registration.identity.commandCodec,
              registration.commandCodec.configuration == registration.identity.commandCodecConfiguration,
              registration.effectCodec.identifier == registration.identity.effectCodec,
              registration.effectCodec.configuration == registration.identity.effectCodecConfiguration,
              delivery.members.allSatisfy({ $0.payload.family == registration.identity.operation }) else {
            return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable))
        }
        let typedOutcome: HistoryTypedOutcome<Effect>
        do {
            switch delivery.kind {
            case .command:
                guard delivery.members.allSatisfy({ $0.payload.version == registration.identity.commandVersion }) else {
                    return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable))
                }
                let commands = try delivery.members.map { member in
                    (member.id, try registration.commandCodec.decode(decodeEnvelope(
                        member.payload.data, codec: registration.identity.commandCodec,
                        configuration: registration.identity.commandCodecConfiguration
                    )))
                }
                typedOutcome = await apply(commands, token: delivery.token)
            case .undo, .redo:
                guard delivery.members.allSatisfy({ $0.payload.version == registration.identity.effectVersion }) else {
                    return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable))
                }
                let effects = try delivery.members.map { member in
                    (member.id, try registration.effectCodec.decode(decodeEnvelope(
                        member.payload.data, codec: registration.identity.effectCodec,
                        configuration: registration.identity.effectCodecConfiguration
                    )))
                }
                typedOutcome = delivery.kind == .undo
                    ? await undo(effects, token: delivery.token)
                    : await redo(effects, token: delivery.token)
            }
        } catch {
            return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable,
                                          underlyingDescription: String(describing: error)))
        }
        switch typedOutcome {
        case .rejected: return .rejected
        case .unresolved: return .unresolved
        case .accepted(let effects):
            guard effects.count == delivery.members.count,
                  effects.map(\.memberID) == delivery.members.map(\.id) else { return .unresolved }
            do {
                return .accepted(try effects.map { effect in
                    HistoryEffect(memberID: effect.memberID,
                                  undo: HistoryPayload(
                                    family: registration.identity.operation,
                                    version: registration.identity.effectVersion,
                                    data: try encodeEnvelope(
                                        effect.undo,
                                        codec: registration.effectCodec,
                                        identity: registration.identity
                                    )
                                  ),
                                  redo: HistoryPayload(
                                    family: registration.identity.operation,
                                    version: registration.identity.effectVersion,
                                    data: try encodeEnvelope(
                                        effect.redo,
                                        codec: registration.effectCodec,
                                        identity: registration.identity
                                    )
                                  )
                    )
                })
            } catch { return .unresolved }
        }
    }

    internal func lookup(_ token: HistoryToken,
                            registration: HistoryOperationRegistration<Self>) async -> HistoryHostOutcome {
        do {
            switch await outcome(for: token) {
            case .rejected: return .rejected
            case .unresolved: return .unresolved
            case .accepted(let effects):
                return .accepted(try effects.map { effect in
                    HistoryEffect(memberID: effect.memberID,
                                  undo: HistoryPayload(family: registration.identity.operation,
                                                       version: registration.identity.effectVersion,
                                                       data: try encodeEnvelope(effect.undo, codec: registration.effectCodec,
                                                                                identity: registration.identity)),
                                  redo: HistoryPayload(family: registration.identity.operation,
                                                       version: registration.identity.effectVersion,
                                                       data: try encodeEnvelope(effect.redo, codec: registration.effectCodec,
                                                                                identity: registration.identity)))
                })
            }
        } catch { return .unresolved }
    }
}
