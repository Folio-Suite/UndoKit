// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// An authoritative field value and opaque host revision. Equal values do not establish equal revisions.
public struct HistoryFieldSnapshot<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value
    public let revision: Data
    public init(value: Value, revision: Data) {
        self.value = value
        self.revision = revision
    }
}

/// Declares one optional field draft and its mapping to an ordinary typed operation.
/// The host reads authoritative revisions and defines semantic intent; UndoKit owns its journal.
@MainActor public struct HistoryField<Value: Equatable & Sendable> {
    public let id: String
    public let mappingID: String
    public let codec: HistoryCodec<Value>
    public let version: Int
    let operationIdentity: UUID
    let session: HistorySession
    let read: @MainActor () async throws -> HistoryFieldSnapshot<Value>
    let prepare: @MainActor (HistoryFieldSnapshot<Value>, Value, UUID) async throws -> HistoryCommand?

    public init<Command: Sendable>(
        id: String, mappingID: String, codec: HistoryCodec<Value>, version: Int = 1,
        commands: HistoryCommands<Command>,
        read: @escaping @MainActor () async throws -> HistoryFieldSnapshot<Value>,
        makeCommands: @escaping @MainActor (HistoryFieldSnapshot<Value>, Value) throws -> [Command]
    ) {
        self.id = id
        self.mappingID = mappingID
        self.codec = codec
        self.version = version
        operationIdentity = commands.operation.erased.identity
        session = commands.session
        self.read = read
        prepare = { base, proposed, generation in
            let values = try makeCommands(base, proposed)
            guard !values.isEmpty else { return nil }
            return try await commands.encode(values, generation: generation)
        }
    }
}
