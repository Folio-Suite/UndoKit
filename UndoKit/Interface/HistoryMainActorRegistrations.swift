// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

@MainActor public extension MainActorHistoryOperationHandler {
    // MARK: - Typed submission and checkpoints

    /// Encodes and submits a Command on the main actor with the current host codec.
    /// - Parameters:
    ///   - command: Host value and stable canonical intent fingerprint.
    ///   - registration: Current command version and codec used for this write.
    ///   - engine: Scope to prepare, deliver, and finalize the command.
    /// - Returns: An accepted receipt after finalization, authoritative rejection, or structured failure.
    ///   Cancellation after delivery may leave a suspended scope for reconciliation.
    func submit(_ command: HistoryTypedCommand<Command>,
                using registration: HistoryOperationRegistration<Self>,
                to engine: any HistoryTransactions) async -> HistoryResult {
        await submitRegistered(command, using: registration, to: engine)
    }

    /// Encodes a coherent host state on the main actor for checkpoint storage.
    /// - Parameters:
    ///   - state: Host-owned state to persist.
    ///   - registration: Current state version and codec used for this write.
    /// - Returns: An opaque payload with the current state version and codec envelope.
    /// - Throws: A compatibility failure for invalid registration, or a codec error.
    func encodeState(_ state: State, using registration: HistoryOperationRegistration<Self>) throws -> HistoryPayload {
        try encodeRegisteredState(state, using: registration)
    }

    /// Decodes checkpoint state on the main actor using a registered host version.
    /// The stored payload is read without modification.
    /// - Parameters:
    ///   - payload: The opaque checkpoint state, including its host schema version.
    ///   - registration: Current codec and explicit older decoders.
    /// - Returns: The host-owned state value.
    /// - Throws: A compatibility failure for an unknown version or mismatched envelope, or a codec error.
    func decodeState(_ payload: HistoryPayload,
                     using registration: HistoryOperationRegistration<Self>) throws -> State {
        try decodeRegisteredState(payload, using: registration)
    }
}
