// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

public extension HistoryOperationHandler {
    /// Encodes a coherent state on this handler's actor for checkpoint storage.
    /// - Parameters:
    ///   - state: Host-owned state to persist.
    ///   - registration: Current version and codec; older decoders are never used for writes.
    /// - Returns: An opaque payload with the current state version and codec envelope.
    /// - Throws: A compatibility failure for invalid registration, or a codec error.
    func encodeState(_ state: State, using registration: HistoryOperationRegistration<Self>) throws -> HistoryPayload {
        guard registration.stateCodec.identifier == registration.identity.stateCodec,
              registration.stateCodec.configuration == registration.identity.stateCodecConfiguration,
              registration.identity.stateVersion > 0 else {
            throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
        }
        return HistoryPayload(family: registration.identity.operation,
                              version: registration.identity.stateVersion,
                              data: try encodeEnvelope(state, using: registration.stateCodec))
    }

    /// Decodes checkpoint state on this handler's actor using a registered version.
    /// The stored payload is read without modification.
    /// - Parameters:
    ///   - payload: The opaque checkpoint state, including its host schema version.
    ///   - registration: Current codec and explicit older decoders.
    /// - Returns: The host-owned state value.
    /// - Throws: A compatibility failure for an unknown version or mismatched envelope, or a codec error.
    func decodeState(
        _ payload: HistoryPayload,
        using registration: HistoryOperationRegistration<Self>
    ) throws -> State {
        guard payload.family == registration.identity.operation,
              let codec = registration.stateDecoder(for: payload.version) else {
            throw HistoryFailure(.compatibility, stage: .reconciliation, disposition: .usable)
        }
        return try decodeEnvelope(payload.data, using: codec, stage: .reconciliation)
    }

    /// Encodes and submits a Command while the caller remains on this handler's actor.
    /// - Parameters:
    ///   - command: Host value and stable canonical intent fingerprint.
    ///   - registration: Current command version and codec used for this write.
    ///   - engine: Scope to prepare, deliver, and finalize the command.
    /// - Returns: An accepted receipt after finalization, authoritative rejection, or structured failure.
    ///   Cancellation after delivery may leave a suspended scope for reconciliation.
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
            return await engine.submit(HistoryCommand(
                id: command.id, fingerprint: command.fingerprint,
                payload: HistoryPayload(family: registration.identity.operation,
                                        version: registration.identity.commandVersion,
                                        data: try encodeEnvelope(command.value, using: registration.commandCodec))
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
                effect = await apply(try registration.decodeCommands(delivery.members), token: delivery.token)
            case .undo, .redo:
                let typedInputs = try registration.decodeEffects(delivery.members)
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
                return .accepted(try registration.encodeEffects(effects))
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
                return .accepted(try registration.encodeEffects(effects))
            }
        } catch { return .unresolved }
    }

}
