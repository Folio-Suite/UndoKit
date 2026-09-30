// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

public extension HistoryOperationHandler {
    /// Encodes a coherent historical state on the host's actor for checkpoint storage.
    func encodeState(_ state: State, using registration: HistoryOperationRegistration<Self>) throws -> HistoryPayload {
        guard registration.stateCodec.identifier == registration.identity.stateCodec,
              registration.stateCodec.configuration == registration.identity.stateCodecConfiguration,
              registration.identity.stateVersion > 0 else {
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

    /// Decodes checkpoint state only after checking its operation, version and codec identity.
    func decodeState(
        _ payload: HistoryPayload,
        using registration: HistoryOperationRegistration<Self>
    ) throws -> State {
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

    /// Encodes and submits a Command while the caller remains on this handler's actor.
    func submit(_ command: HistoryTypedCommand<Command>,
                using registration: HistoryOperationRegistration<Self>,
                to engine: HistoryEngine) async -> HistoryResult {
        guard !registration.identity.operation.isEmpty,
              registration.identity.commandVersion > 0,
              registration.commandCodec.identifier == registration.identity.commandCodec,
              registration.commandCodec.configuration == registration.identity.commandCodecConfiguration else {
            return .failure(HistoryFailure(.compatibility, stage: .admission, disposition: .usable))
        }
        do {
            let data = try registration.commandCodec.encode(command.value)
            let envelope = HistoryCodecEnvelope(codec: registration.identity.commandCodec,
                                                configuration: registration.identity.commandCodecConfiguration,
                                                bytes: data)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return await engine.submit(HistoryCommand(
                id: command.id, fingerprint: command.fingerprint,
                payload: HistoryPayload(family: registration.identity.operation,
                                        version: registration.identity.commandVersion,
                                        data: try encoder.encode(envelope))
            ))
        } catch {
            return .failure(HistoryFailure(.compatibility, stage: .admission,
                                          disposition: .usable,
                                          underlyingDescription: String(describing: error)))
        }
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
        let effect: HistoryTypedOutcome<Effect>
        do {
            switch delivery.kind {
            case .command:
                guard delivery.members.allSatisfy({ $0.payload.version == registration.identity.commandVersion }) else {
                    return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable))
                }
                let values = try delivery.members.map { member in
                    (member.id, try registration.commandCodec.decode(unwrap(member.payload.data,
                                                                             identity: registration.identity,
                                                                             command: true)))
                }
                effect = await apply(values, token: delivery.token)
            case .undo, .redo:
                guard delivery.members.allSatisfy({ $0.payload.version == registration.identity.effectVersion }) else {
                    return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable))
                }
                let typedInputs = try delivery.members.map { member in
                    (member.id, try registration.effectCodec.decode(unwrap(member.payload.data,
                                                                           identity: registration.identity,
                                                                           command: false)))
                }
                effect = delivery.kind == .undo
                    ? await undo(typedInputs, token: delivery.token)
                    : await redo(typedInputs, token: delivery.token)
            }
        } catch {
            return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable,
                                          underlyingDescription: String(describing: error)))
        }
        switch effect {
        case .rejected: return .rejected
        case .unresolved: return .unresolved
        case .accepted(let effects):
            guard effects.count == delivery.members.count,
                  effects.map(\.memberID) == delivery.members.map(\.id) else { return .unresolved }
            do {
                return .accepted(try effects.map { item in
                    HistoryEffect(
                        memberID: item.memberID,
                        undo: HistoryPayload(family: registration.identity.operation,
                                             version: registration.identity.effectVersion,
                                             data: try wrap(registration.effectCodec.encode(item.undo),
                                                            identity: registration.identity, command: false)),
                        redo: HistoryPayload(family: registration.identity.operation,
                                             version: registration.identity.effectVersion,
                                             data: try wrap(registration.effectCodec.encode(item.redo),
                                                            identity: registration.identity, command: false))
                    )
                })
            } catch {
                // The host already returned an accepted effect, but UndoKit cannot
                // persist its required evidence. Reconciliation must remain unresolved.
                return .unresolved
            }
        }
    }

    internal func lookup(
        _ token: HistoryToken,
        registration: HistoryOperationRegistration<Self>
    ) async -> HistoryHostOutcome {
        do {
            switch await outcome(for: token) {
            case .rejected: return .rejected
            case .unresolved: return .unresolved
            case .accepted(let effects):
                return .accepted(try effects.map { effect in
                    HistoryEffect(
                        memberID: effect.memberID,
                        undo: HistoryPayload(family: registration.identity.operation,
                                             version: registration.identity.effectVersion,
                                             data: try wrap(registration.effectCodec.encode(effect.undo),
                                                            identity: registration.identity, command: false)),
                        redo: HistoryPayload(family: registration.identity.operation,
                                             version: registration.identity.effectVersion,
                                             data: try wrap(registration.effectCodec.encode(effect.redo),
                                                            identity: registration.identity, command: false))
                    )
                })
            }
        } catch { return .unresolved }
    }

    internal func wrap(_ bytes: Data, identity: HistorySchemaIdentity, command: Bool) throws -> Data {
        let envelope = HistoryCodecEnvelope(
            codec: command ? identity.commandCodec : identity.effectCodec,
            configuration: command ? identity.commandCodecConfiguration : identity.effectCodecConfiguration,
            bytes: bytes
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(envelope)
    }

    internal func unwrap(_ bytes: Data, identity: HistorySchemaIdentity, command: Bool) throws -> Data {
        let envelope = try PropertyListDecoder().decode(HistoryCodecEnvelope.self, from: bytes)
        let codec = command ? identity.commandCodec : identity.effectCodec
        let configuration = command ? identity.commandCodecConfiguration : identity.effectCodecConfiguration
        guard envelope.codec == codec, envelope.configuration == configuration else {
            throw HistoryFailure(.compatibility, stage: .delivery, disposition: .usable)
        }
        return envelope.bytes
    }
}

