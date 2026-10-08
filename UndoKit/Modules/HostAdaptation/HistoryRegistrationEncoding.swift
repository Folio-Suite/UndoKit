// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

extension HistoryOperationRegistration {
    func commandDecoder(for version: Int) -> HistoryCodec<Handler.Command>? {
        decoder(for: version, currentVersion: identity.commandVersion,
                current: commandCodec, old: oldCommandCodecs)
    }

    func effectDecoder(for version: Int) -> HistoryCodec<Handler.Effect>? {
        decoder(for: version, currentVersion: identity.effectVersion,
                current: effectCodec, old: oldEffectCodecs)
    }

    func stateDecoder(for version: Int) -> HistoryCodec<Handler.State>? {
        decoder(for: version, currentVersion: identity.stateVersion,
                current: stateCodec, old: oldStateCodecs)
    }

    private func decoder<Value>(for version: Int, currentVersion: Int,
                                current: HistoryCodec<Value>, old: [Int: HistoryCodec<Value>]) -> HistoryCodec<Value>? {
        guard version > 0 else { return nil }
        if version == currentVersion { return current }
        guard version < currentVersion else { return nil }
        return old[version]
    }

    func decodeCommands(_ members: [HistoryMember]) throws -> [(UUID, Handler.Command)] {
        try members.map { member in
            guard let codec = commandDecoder(for: member.payload.version) else {
                throw HistoryFailure(.compatibility, stage: .delivery, disposition: .usable)
            }
            return (member.id, try decodeEnvelope(member.payload.data, using: codec, stage: .delivery))
        }
    }

    func decodeEffects(_ members: [HistoryMember]) throws -> [(UUID, Handler.Effect)] {
        try members.map { member in
            guard let codec = effectDecoder(for: member.payload.version) else {
                throw HistoryFailure(.compatibility, stage: .delivery, disposition: .usable)
            }
            return (member.id, try decodeEnvelope(member.payload.data, using: codec, stage: .delivery))
        }
    }

    func encodeEffects(_ effects: [HistoryTypedEffect<Handler.Effect>]) throws -> [HistoryEffect] {
        try effects.map { effect in
            HistoryEffect(
                memberID: effect.memberID,
                undo: HistoryPayload(family: identity.operation, version: identity.effectVersion,
                                     data: try encodeEnvelope(effect.undo, using: effectCodec)),
                redo: HistoryPayload(family: identity.operation, version: identity.effectVersion,
                                     data: try encodeEnvelope(effect.redo, using: effectCodec)),
                resources: effect.resources
            )
        }
    }
}
