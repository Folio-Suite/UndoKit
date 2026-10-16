// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// A typed capability tied to this session epoch, generation and registered handler.
public struct HistoryCommands<Command: Sendable>: Sendable {
    let session: HistorySession
    let operation: HistoryOperation<Command>
    let epoch: UUID
    let generation: UUID

    // MARK: - Submit typed intent

    /// Hosts must capture stable intent in their operation declaration when a Command
    /// contains mutable references. Transferability alone does not freeze their values.
    @MainActor public func submit(_ command: Command) async -> HistorySubmissionResult {
        await submitGroup([command])
    }

    /// Every member is delivered to one host callback and accepted atomically.
    @MainActor public func submitGroup(_ commands: [Command]) async -> HistorySubmissionResult {
        await session.submit(commands, using: self)
    }

    // MARK: - Controlled failure evidence

    #if DEBUG
    @MainActor public func submitGroupWithInjectedFinalizationFailure(_ commands: [Command]) async
        -> HistorySubmissionResult {
        await session.submit(commands, using: self, injectFinalizationFailure: true)
    }
    @MainActor public func submitWithInjectedFinalizationFailure(_ command: Command) async -> HistorySubmissionResult {
        await submitGroupWithInjectedFinalizationFailure([command])
    }
    #endif

    @MainActor func encode(_ values: [Command], generation: UUID) async throws -> HistoryCommand {
        try session.requireHandle(epoch: epoch, generation: self.generation, operation: operation.erased)
        return try await operation.encodeValues(values.map(operation.capture), generation)
    }
}
