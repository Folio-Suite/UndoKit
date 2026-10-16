// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Actor-local operation setup for values that deliberately do not cross actors.
public struct HistoryLocalOperation<Handler: HistoryTypedOperationHandler>: Sendable {
    public let erased: AnyHistoryOperation
    let definition: HistorySessionOperationDefinition<Handler>
}

extension HistoryLocalOperation where Handler: HistoryOperationHandler {
    public init(
        operation: String, commandVersion: Int = 1, effectVersion: Int = 1,
        commandCodec: HistoryCodec<Handler.Command>, effectCodec: HistoryCodec<Handler.Effect>,
        handler: Handler, fingerprint: @escaping @Sendable ([Handler.Command]) throws -> Data,
        metadata: @escaping @Sendable ([Handler.Command]) throws -> HistoryOperationMetadata = { _ in
            HistoryOperationMetadata()
        }
    ) throws {
        let definition = try HistorySessionOperationDefinition(
            operation: operation,
            commandVersion: commandVersion, effectVersion: effectVersion, commandCodec: commandCodec,
            effectCodec: effectCodec, handler: handler, fingerprint: fingerprint, metadata: metadata)
        self.definition = definition
        erased = AnyHistoryOperation(
            operation: operation, identity: definition.identity,
            host: HistorySessionActorHost(definition: definition))
    }
}

extension HistoryLocalOperation where Handler: MainActorHistoryOperationHandler {
    public init(
        operation: String, commandVersion: Int = 1, effectVersion: Int = 1,
        commandCodec: HistoryCodec<Handler.Command>, effectCodec: HistoryCodec<Handler.Effect>,
        handler: Handler, fingerprint: @escaping @Sendable ([Handler.Command]) throws -> Data,
        metadata: @escaping @Sendable ([Handler.Command]) throws -> HistoryOperationMetadata = { _ in
            HistoryOperationMetadata()
        }
    ) throws {
        let definition = try HistorySessionOperationDefinition(
            operation: operation,
            commandVersion: commandVersion, effectVersion: effectVersion, commandCodec: commandCodec,
            effectCodec: effectCodec, handler: handler, fingerprint: fingerprint, metadata: metadata)
        self.definition = definition
        erased = AnyHistoryOperation(
            operation: operation, identity: definition.identity,
            host: HistorySessionMainActorHost(definition: definition))
    }
}

public struct HistoryLocalCommands<Handler: HistoryTypedOperationHandler>: Sendable {
    let session: HistorySession
    let operation: HistoryLocalOperation<Handler>
    let epoch: UUID
    let generation: UUID
}

extension HistoryOperationHandler {
    /// Freeze canonical intent and encoded bytes synchronously on this handler's actor.
    /// The non-Sendable value is never retained by, or passed to, the session queue.
    public func submit(
        _ command: Command, using commands: HistoryLocalCommands<Self>
    ) async -> HistorySubmissionResult {
        await submitGroup([command], using: commands)
    }
    public func submitGroup(_ values: [Command], using commands: HistoryLocalCommands<Self>) async
        -> HistorySubmissionResult {
        guard commands.operation.definition.handler === self else {
            return .unexecuted(HistoryFailure(.identityConflict, stage: .admission, disposition: .usable))
        }
        do {
            let encoded = try commands.operation.definition.encode(values, generation: commands.generation)
            return await commands.session.submitEncoded(
                encoded, epoch: commands.epoch,
                generation: commands.generation, operation: commands.operation.erased)
        } catch {
            return .unexecuted(
                HistoryFailure(
                    .invalidInput, stage: .admission, disposition: .usable,
                    underlyingDescription: String(describing: error)))
        }
    }
}

@MainActor extension MainActorHistoryOperationHandler {
    public func submit(
        _ command: Command, using commands: HistoryLocalCommands<Self>
    ) async -> HistorySubmissionResult {
        await submitGroup([command], using: commands)
    }
    public func submitGroup(_ values: [Command], using commands: HistoryLocalCommands<Self>) async
        -> HistorySubmissionResult {
        guard commands.operation.definition.handler === self else {
            return .unexecuted(HistoryFailure(.identityConflict, stage: .admission, disposition: .usable))
        }
        do {
            let encoded = try commands.operation.definition.encode(values, generation: commands.generation)
            return await commands.session.submitEncoded(
                encoded, epoch: commands.epoch,
                generation: commands.generation, operation: commands.operation.erased)
        } catch {
            return .unexecuted(
                HistoryFailure(
                    .invalidInput, stage: .admission, disposition: .usable,
                    underlyingDescription: String(describing: error)))
        }
    }
}

extension HistorySession {
    public func localCommands<Handler>(for operation: HistoryLocalOperation<Handler>) throws -> HistoryLocalCommands<
        Handler
    > {
        guard let generation = engine?.snapshot.generation else { throw failure(.busy) }
        try requireHandle(epoch: epoch, generation: generation, operation: operation.erased)
        return HistoryLocalCommands(session: self, operation: operation, epoch: epoch, generation: generation)
    }
    func submitEncoded(
        _ command: HistoryCommand, epoch: UUID, generation: UUID,
        operation: AnyHistoryOperation
    ) async -> HistorySubmissionResult {
        do {
            try requireHandle(epoch: epoch, generation: generation, operation: operation)
            guard let engine else { throw failure(.missingHistory) }
            return HistorySubmissionResult(await engine.submit(command))
        } catch { return .unexecuted(Self.describe(error, stage: .admission)) }
    }
}
