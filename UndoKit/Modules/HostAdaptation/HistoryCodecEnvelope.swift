// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

struct HistoryCodecEnvelope: Codable, Sendable {
    let codec: String
    let configuration: Data
    let bytes: Data
}

func decodeEnvelope<Value>(_ data: Data, using codec: HistoryCodec<Value>,
                           stage: HistoryFailureStage) throws -> Value {
    let envelope = try PropertyListDecoder().decode(HistoryCodecEnvelope.self, from: data)
    guard envelope.codec == codec.identifier, envelope.configuration == codec.configuration else {
        throw HistoryFailure(.compatibility, stage: stage, disposition: .usable)
    }
    return try codec.decode(envelope.bytes)
}

func encodeEnvelope<Value>(_ value: Value, using codec: HistoryCodec<Value>) throws -> Data {
    let envelope = HistoryCodecEnvelope(codec: codec.identifier,
                                        configuration: codec.configuration,
                                        bytes: try codec.encode(value))
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try encoder.encode(envelope)
}
