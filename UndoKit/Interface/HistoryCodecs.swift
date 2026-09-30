// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

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

private enum FoundationHistoryEncoding<Value: Codable> {
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

/// A stable schema identity registered by host code when opening a history.
/// Runtime closures and model objects are rebuilt after reopening; only these
/// identities, versions and encoded values belong in durable history.
public struct HistorySchemaIdentity: Hashable, Sendable {
    public let operation: String
    public let commandCodec: String
    public let effectCodec: String
    public let stateCodec: String
    public let commandCodecConfiguration: Data
    public let effectCodecConfiguration: Data
    public let stateCodecConfiguration: Data
    public let commandVersion: Int
    public let effectVersion: Int
    public let stateVersion: Int

    /// Declares the host's current write versions and codec identities.
    /// Older read versions are registered separately in ``HistoryOperationRegistration``;
    /// changing these values does not rewrite stored payloads.
    /// - Parameters:
    ///   - operation: Stable host operation family.
    ///   - commandCodec: Current Command codec identifier.
    ///   - effectCodec: Current effect codec identifier.
    ///   - stateCodec: Current checkpoint state codec identifier.
    ///   - commandCodecConfiguration: Current Command codec settings.
    ///   - effectCodecConfiguration: Current effect codec settings.
    ///   - stateCodecConfiguration: Current state codec settings.
    ///   - commandVersion: Current Command write version.
    ///   - effectVersion: Current effect write version.
    ///   - stateVersion: Current state write version.
    public init(operation: String, commandCodec: String, effectCodec: String,
                stateCodec: String = "undokit.state",
                commandCodecConfiguration: Data = Data(), effectCodecConfiguration: Data = Data(),
                stateCodecConfiguration: Data = Data(), commandVersion: Int = 1,
                effectVersion: Int = 1, stateVersion: Int = 1) {
        self.operation = operation
        self.commandCodec = commandCodec
        self.effectCodec = effectCodec
        self.stateCodec = stateCodec
        self.commandCodecConfiguration = commandCodecConfiguration
        self.effectCodecConfiguration = effectCodecConfiguration
        self.stateCodecConfiguration = stateCodecConfiguration
        self.commandVersion = commandVersion
        self.effectVersion = effectVersion
        self.stateVersion = stateVersion
    }
}

/// A typed Command paired with its stable host-supplied intent fingerprint.
/// The fingerprint is never inferred from an ordinary codec's output.
public struct HistoryTypedCommand<Value> {
    public let id: UUID
    public let fingerprint: Data
    public let value: Value

    /// Pairs a host-owned value with its stable identity and canonical intent fingerprint.
    /// The value stays on the handler's actor; the fingerprint is passed to UndoKit unchanged.
    /// - Parameters:
    ///   - id: Stable identity reused for a retry of the same intent.
    ///   - fingerprint: Host-supplied fingerprint of canonical intent.
    ///   - value: Typed Command value to encode before submission.
    public init(id: UUID = UUID(), fingerprint: Data, value: Value) {
        self.id = id
        self.fingerprint = fingerprint
        self.value = value
    }
}

/// Result from a typed host operation. Rejection must prove no semantic effect.
public enum HistoryTypedOutcome<Effect> {
    case accepted([HistoryTypedEffect<Effect>])
    case rejected
    case unresolved
}

public struct HistoryTypedEffect<Effect> {
    public let memberID: UUID
    public let undo: Effect
    public let redo: Effect

    /// Supplies typed compensation and reapplication evidence for one member.
    /// Values stay on the handler's actor until encoded for durable history.
    /// - Parameters:
    ///   - memberID: Accepted member this evidence belongs to.
    ///   - undo: Value interpreted by the host's Undo callback.
    ///   - redo: Value interpreted by the host's Redo callback.
    public init(memberID: UUID, undo: Effect, redo: Effect) {
        self.memberID = memberID
        self.undo = undo
        self.redo = redo
    }
}

/// Common typed values for an operation handler. Values need not be `Sendable`.
public protocol HistoryTypedOperationHandler: Sendable {
    associatedtype Command
    associatedtype Effect
    associatedtype State
}

/// An actor that owns one operation family's domain values and acceptance rules.
/// The adapter decodes and invokes it on its actor; only encoded values cross to UndoKit.
public protocol HistoryOperationHandler: Actor, HistoryTypedOperationHandler {

    /// Applies all commands atomically or proves that none took effect.
    func apply(_ commands: [(UUID, Command)], token: HistoryToken) async -> HistoryTypedOutcome<Effect>
    /// Reverses the entire group atomically or proves that none took effect.
    func undo(_ effects: [(UUID, Effect)], token: HistoryToken) async -> HistoryTypedOutcome<Effect>
    /// Reapplies the entire group atomically or proves that none took effect.
    func redo(_ effects: [(UUID, Effect)], token: HistoryToken) async -> HistoryTypedOutcome<Effect>
    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<Effect>
}

/// A main-actor variant for Cocoa document models and other main-actor-owned data.
@MainActor public protocol MainActorHistoryOperationHandler: AnyObject, HistoryTypedOperationHandler {
    func apply(_ commands: [(UUID, Command)], token: HistoryToken) async -> HistoryTypedOutcome<Effect>
    func undo(_ effects: [(UUID, Effect)], token: HistoryToken) async -> HistoryTypedOutcome<Effect>
    func redo(_ effects: [(UUID, Effect)], token: HistoryToken) async -> HistoryTypedOutcome<Effect>
    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<Effect>
}
