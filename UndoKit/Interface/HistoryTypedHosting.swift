// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Derived schema identity

/// A schema identity derived from a validated operation registration.
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
}

// MARK: - Commands and accepted evidence

/// A typed Command paired with its stable host-supplied intent fingerprint.
/// The fingerprint is never inferred from an ordinary codec's output.
public struct HistoryTypedCommand<Value> {
    public let id: UUID
    public let fingerprint: Data
    public let value: Value
    /// Historical state this command restores, when supplied by the host.
    public let restorationOrigin: UUID?
    /// Bounded opaque display metadata, independent of recovery evidence.
    public let presentation: HistoryPayload?
    public let expectedGeneration: UUID?

    /// Pairs a host-owned value with its stable identity and canonical intent fingerprint.
    /// The value stays on the handler's actor; the fingerprint is passed to UndoKit unchanged.
    /// - Parameters:
    ///   - id: Stable identity reused for a retry of the same intent.
    ///   - fingerprint: Host-supplied fingerprint of canonical intent.
    ///   - value: Typed Command value to encode before submission.
    ///   - restorationOrigin: Historical state restored by this new Command.
    ///   - presentation: Optional display metadata, subject to the ordinary payload limits.
    ///   - expectedGeneration: Generation captured when this request was created;
    ///     required after reset so delayed values cannot enter the new generation.
    public init(id: UUID = UUID(), fingerprint: Data, value: Value,
                restorationOrigin: UUID? = nil, presentation: HistoryPayload? = nil,
                expectedGeneration: UUID? = nil) {
        self.id = id
        self.fingerprint = fingerprint
        self.value = value
        self.restorationOrigin = restorationOrigin
        self.presentation = presentation
        self.expectedGeneration = expectedGeneration
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
    /// Opaque dependencies secured by the host before reporting acceptance.
    public let resources: [HistoryObjectReference]

    /// Supplies typed compensation and reapplication evidence for one member.
    /// Values stay on the handler's actor until encoded for durable history.
    /// - Parameters:
    ///   - memberID: Accepted member this evidence belongs to.
    ///   - undo: Value interpreted by the host's Undo callback.
    ///   - redo: Value interpreted by the host's Redo callback.
    ///   - resources: Objects and versions required to interpret this accepted effect.
    public init(memberID: UUID, undo: Effect, redo: Effect,
                resources: [HistoryObjectReference] = []) {
        self.memberID = memberID
        self.undo = undo
        self.redo = redo
        self.resources = resources
    }
}

// MARK: - Handler contracts

/// Structural metadata accompanying a whole-group typed host callback.
/// The token binds durable outcome evidence; the host interprets restoration provenance.
public struct HistoryOperationContext: Sendable {
    /// Bind this token to the host's durable receipt in the same atomic domain change.
    public let token: HistoryToken
    /// The host-authored historical origin of a restoration Command, when supplied.
    public let restorationOrigin: UUID?

    public init(token: HistoryToken, restorationOrigin: UUID? = nil) {
        self.token = token
        self.restorationOrigin = restorationOrigin
    }
}

/// Common typed values for an operation handler. Values need not be `Sendable`.
public protocol HistoryTypedOperationHandler: AnyObject, Sendable {
    associatedtype Command
    associatedtype Effect
    associatedtype State
}

/// An actor that owns one operation family's domain values and acceptance rules.
/// The adapter decodes and invokes it on its actor; only encoded values cross to UndoKit.
public protocol HistoryOperationHandler: Actor, HistoryTypedOperationHandler {
    /// Applies all commands atomically or proves that none took effect.
    func apply(_ commands: [(UUID, Command)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Effect>
    /// Reverses the entire group atomically or proves that none took effect.
    func undo(_ effects: [(UUID, Effect)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Effect>
    /// Reapplies the entire group atomically or proves that none took effect.
    func redo(_ effects: [(UUID, Effect)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Effect>
    /// Reads durable evidence without applying a Command again; absence is unresolved.
    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<Effect>
}

/// A main-actor variant for Cocoa document models and other main-actor-owned data.
@MainActor public protocol MainActorHistoryOperationHandler: AnyObject, HistoryTypedOperationHandler {
    /// Applies all commands atomically and persists the context token with the outcome.
    func apply(_ commands: [(UUID, Command)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Effect>
    /// Reverses the whole group atomically or proves that none took effect.
    func undo(_ effects: [(UUID, Effect)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Effect>
    /// Reapplies the whole group atomically or proves that none took effect.
    func redo(_ effects: [(UUID, Effect)], context: HistoryOperationContext) async -> HistoryTypedOutcome<Effect>
    /// Reads durable evidence without applying a Command again; absence is unresolved.
    func outcome(for token: HistoryToken) async -> HistoryTypedOutcome<Effect>
}
