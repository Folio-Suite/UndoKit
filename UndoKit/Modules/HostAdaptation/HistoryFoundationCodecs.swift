// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

enum FoundationHistoryEncoding<Value: Codable> {
    static func encodeJSON(_ value: Value) throws -> Data { try JSONEncoder().encode(value) }
    static func decodeJSON(_ data: Data) throws -> Value { try JSONDecoder().decode(Value.self, from: data) }

    static func encodePropertyList(
        _ value: Value, format: PropertyListSerialization.PropertyListFormat
    ) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = format
        return try encoder.encode(value)
    }

    static func decodePropertyList(_ data: Data) throws -> Value {
        try PropertyListDecoder().decode(Value.self, from: data)
    }
}
