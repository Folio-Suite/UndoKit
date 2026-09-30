// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

struct HistoryCodecEnvelope: Codable, Sendable {
    let codec: String
    let configuration: Data
    let bytes: Data
}

extension HistoryRegisteredHost {
    public func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        await registration.handler.deliver(delivery, registration: registration)
    }

    public func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        await registration.handler.lookup(token, registration: registration)
    }
}

@MainActor extension MainActorHistoryRegisteredHost {
    public func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        await registration.handler.deliver(delivery, registration: registration)
    }

    public func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        await registration.handler.lookup(token, registration: registration)
    }
}

func decodeEnvelope(_ data: Data, codec: String, configuration: Data) throws -> Data {
    let envelope = try PropertyListDecoder().decode(HistoryCodecEnvelope.self, from: data)
    guard envelope.codec == codec, envelope.configuration == configuration else {
        throw HistoryFailure(.compatibility, stage: .delivery, disposition: .usable)
    }
    return envelope.bytes
}

func encodeEnvelope<Value>(_ value: Value, codec: HistoryCodec<Value>,
                           identity: HistorySchemaIdentity) throws -> Data {
    let envelope = HistoryCodecEnvelope(codec: identity.effectCodec,
                                        configuration: identity.effectCodecConfiguration,
                                        bytes: try codec.encode(value))
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try encoder.encode(envelope)
}
