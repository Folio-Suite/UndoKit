// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// One registered operation, bound to its actual host adapter rather than a Swift type name.
public struct AnyHistoryOperation: Sendable {
    public let operation: String
    let identity: UUID
    let host: any HistoryHost
}

/// Define the family, codecs, canonical intent and handler once during session setup.
/// Checkpoint support is independent of this declaration.
public struct HistoryOperation<Command: Sendable>: Sendable {
    public let erased: AnyHistoryOperation
    let capture: @Sendable (Command) throws -> Command
    let encodeValues: @Sendable ([Command], UUID) async throws -> HistoryCommand

    public init<Handler: HistoryOperationHandler>(
        operation: String, commandVersion: Int = 1, effectVersion: Int = 1,
        commandCodec: HistoryCodec<Command>, effectCodec: HistoryCodec<Handler.Effect>,
        handler: Handler, fingerprint: @escaping @Sendable ([Command]) throws -> Data,
        metadata: @escaping @Sendable ([Command]) throws -> HistoryOperationMetadata = { _ in HistoryOperationMetadata()
        },
        capture: @escaping @Sendable (Command) throws -> Command = { $0 }
    ) throws where Handler.Command == Command {
        let definition = try HistorySessionOperationDefinition(
            operation: operation,
            commandVersion: commandVersion, effectVersion: effectVersion,
            commandCodec: commandCodec, effectCodec: effectCodec, handler: handler,
            fingerprint: fingerprint, metadata: metadata)
        erased = AnyHistoryOperation(
            operation: operation, identity: definition.identity,
            host: HistorySessionActorHost(definition: definition))
        self.capture = capture
        encodeValues = { values, generation in
            try await handler.encodeSessionCommands(values, definition: definition, generation: generation)
        }
    }

    public init<Handler: MainActorHistoryOperationHandler>(
        operation: String, commandVersion: Int = 1, effectVersion: Int = 1,
        commandCodec: HistoryCodec<Command>, effectCodec: HistoryCodec<Handler.Effect>,
        handler: Handler, fingerprint: @escaping @Sendable ([Command]) throws -> Data,
        metadata: @escaping @Sendable ([Command]) throws -> HistoryOperationMetadata = { _ in HistoryOperationMetadata()
        },
        capture: @escaping @Sendable (Command) throws -> Command = { $0 }
    ) throws where Handler.Command == Command {
        let definition = try HistorySessionOperationDefinition(
            operation: operation,
            commandVersion: commandVersion, effectVersion: effectVersion,
            commandCodec: commandCodec, effectCodec: effectCodec, handler: handler,
            fingerprint: fingerprint, metadata: metadata)
        erased = AnyHistoryOperation(
            operation: operation, identity: definition.identity,
            host: HistorySessionMainActorHost(definition: definition))
        self.capture = capture
        encodeValues = { values, generation in
            try await handler.encodeSessionCommands(values, definition: definition, generation: generation)
        }
    }
}
