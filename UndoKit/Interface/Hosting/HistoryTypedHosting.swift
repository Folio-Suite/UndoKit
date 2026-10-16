// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Result from a typed host operation. Rejection must prove no semantic effect.
public enum HistoryTypedOutcome<Effect> {
    /// Every member took effect atomically. Return durable evidence in delivery member order.
    case accepted([HistoryTypedEffect<Effect>])
    /// Authoritative proof that no member changed domain state.
    case rejected
    /// The host cannot prove acceptance or no-effect; preserve evidence for outcome lookup.
    case unresolved
}

/// Actor-local accepted evidence encoded by the registered effect codec.
/// The handler must reconstruct this evidence from its durable receipt after interruption.
public struct HistoryTypedEffect<Effect> {
    /// Delivered member identity to which this accepted evidence belongs.
    public let memberID: UUID
    /// Typed compensation input owned and interpreted by the handler.
    public let undo: Effect
    /// Typed reapplication input owned and interpreted by the handler.
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
    public init(
        memberID: UUID, undo: Effect, redo: Effect,
        resources: [HistoryObjectReference] = []
    ) {
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

    /// Packages engine delivery metadata for a typed host callback; it does not authorize effects.
    public init(token: HistoryToken, restorationOrigin: UUID? = nil) {
        self.token = token
        self.restorationOrigin = restorationOrigin
    }
}

/// Common typed values for an operation handler. Values need not be `Sendable`.
public protocol HistoryTypedOperationHandler: AnyObject, Sendable {
    /// Host-owned intent decoded on the handler’s actor before ordinary execution.
    associatedtype Command
    /// Host-owned compensation and reapplication evidence, distinct from intent if necessary.
    associatedtype Effect
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
