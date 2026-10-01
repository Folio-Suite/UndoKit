// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Host-defined codecs

/// An explicitly identified encoding for one host-defined value.
///
/// The codec identity and configuration are persisted with the host's schema
/// registration, while `HistoryPayload` carries the independently stable
/// operation family and schema version. Encoding and decoding are synchronous
/// so a host can run them on the actor that owns its domain values.
public struct HistoryCodec<Value>: Sendable {
    public let identifier: String
    /// Stable caller-defined codec settings. Built-in Foundation codecs use empty configuration.
    public let configuration: Data
    private let encoder: @Sendable (Value) throws -> Data
    private let decoder: @Sendable (Data) throws -> Value

    /// Creates a host codec. The callbacks run synchronously on the caller's actor;
    /// they may work with non-Sendable values and must preserve their declared format.
    /// - Parameters:
    ///   - identifier: Stable identity stored in each encoded payload envelope.
    ///   - configuration: Stable format settings stored with the identifier.
    ///   - encode: Converts one host value to opaque bytes; errors propagate to the caller.
    ///   - decode: Interprets bytes for this exact codec identity and configuration.
    public init(
        identifier: String,
        configuration: Data = Data(),
        encode: @escaping @Sendable (Value) throws -> Data,
        decode: @escaping @Sendable (Data) throws -> Value
    ) {
        self.identifier = identifier
        self.configuration = configuration
        self.encoder = encode
        self.decoder = decode
    }

    /// Encodes on the caller's actor; throws the host codec's error.
    /// - Parameter value: Host value to encode.
    /// - Returns: Opaque host bytes for the selected representation.
    public func encode(_ value: Value) throws -> Data { try encoder(value) }
    /// Decodes on the caller's actor; throws for malformed or unsupported bytes.
    /// - Parameter data: Opaque host bytes previously written with this codec.
    /// - Returns: A host-owned value.
    public func decode(_ data: Data) throws -> Value { try decoder(data) }
}

// MARK: - Foundation representations

public extension HistoryCodec where Value: Codable & SendableMetatype {
    /// Uses Foundation's JSON defaults, which reject values the representation cannot encode.
    /// - Parameter identifier: Stable codec identity recorded in the envelope.
    /// - Returns: A synchronous codec usable on the host's actor.
    static func json(identifier: String = "undokit.codable.json") -> Self {
        Self(identifier: identifier,
             encode: { try FoundationHistoryEncoding<Value>.encodeJSON($0) },
             decode: { try FoundationHistoryEncoding<Value>.decodeJSON($0) })
    }

    /// Uses Foundation's XML property-list representation and supported Codable values.
    /// - Parameter identifier: Stable codec identity recorded in the envelope.
    /// - Returns: A synchronous codec usable on the host's actor.
    static func xmlPropertyList(identifier: String = "undokit.codable.plist.xml") -> Self {
        Self(identifier: identifier,
             encode: { try FoundationHistoryEncoding<Value>.encodePropertyList($0, format: .xml) },
             decode: { try FoundationHistoryEncoding<Value>.decodePropertyList($0) })
    }

    /// Uses Foundation's binary property-list representation and supported Codable values.
    /// - Parameter identifier: Stable codec identity recorded in the envelope.
    /// - Returns: A synchronous codec usable on the host's actor.
    static func binaryPropertyList(identifier: String = "undokit.codable.plist.binary") -> Self {
        Self(identifier: identifier,
             encode: { try FoundationHistoryEncoding<Value>.encodePropertyList($0, format: .binary) },
             decode: { try FoundationHistoryEncoding<Value>.decodePropertyList($0) })
    }
}
