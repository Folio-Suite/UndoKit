// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

struct HistorySessionOperationDefinition<Handler: HistoryTypedOperationHandler>: Sendable {
    let identity = UUID()
    let operation: String
    let commandVersion: Int
    let effectVersion: Int
    let commandCodec: HistoryCodec<Handler.Command>
    let effectCodec: HistoryCodec<Handler.Effect>
    let handler: Handler
    let fingerprint: @Sendable ([Handler.Command]) throws -> Data
    let metadata: @Sendable ([Handler.Command]) throws -> HistoryOperationMetadata

    init(
        operation: String, commandVersion: Int, effectVersion: Int,
        commandCodec: HistoryCodec<Handler.Command>, effectCodec: HistoryCodec<Handler.Effect>,
        handler: Handler, fingerprint: @escaping @Sendable ([Handler.Command]) throws -> Data,
        metadata: @escaping @Sendable ([Handler.Command]) throws -> HistoryOperationMetadata = { _ in
            HistoryOperationMetadata()
        }
    ) throws {
        try HistoryRegistrationValidation.validate(operation: operation)
        try HistoryRegistrationValidation.validate(commandCodec, version: commandVersion)
        try HistoryRegistrationValidation.validate(effectCodec, version: effectVersion)
        self.operation = operation
        self.commandVersion = commandVersion
        self.effectVersion = effectVersion
        self.commandCodec = commandCodec
        self.effectCodec = effectCodec
        self.handler = handler
        self.fingerprint = fingerprint
        self.metadata = metadata
    }

    func encode(_ values: [Handler.Command], generation: UUID) throws -> HistoryCommand {
        let metadata = try metadata(values)
        return HistoryCommand(
            fingerprint: try fingerprint(values),
            members: try values.map {
                HistoryMember(
                    payload: HistoryPayload(
                        family: operation, version: commandVersion,
                        data: try encodeEnvelope($0, using: commandCodec)))
            }, restorationOrigin: metadata.restorationOrigin, presentation: metadata.presentation,
            expectedGeneration: generation)
    }

    func commands(_ members: [HistoryMember]) throws -> [(UUID, Handler.Command)] {
        try members.map {
            guard $0.payload.family == operation, $0.payload.version == commandVersion else { throw incompatible() }
            return ($0.id, try decodeEnvelope($0.payload.data, using: commandCodec, stage: .delivery))
        }
    }
    func effects(_ members: [HistoryMember]) throws -> [(UUID, Handler.Effect)] {
        try members.map {
            guard $0.payload.family == operation, $0.payload.version == effectVersion else { throw incompatible() }
            return ($0.id, try decodeEnvelope($0.payload.data, using: effectCodec, stage: .delivery))
        }
    }
    func outcome(_ value: HistoryTypedOutcome<Handler.Effect>, members: [UUID]? = nil) -> HistoryHostOutcome {
        switch value {
        case .rejected: return .rejected
        case .unresolved: return .unresolved
        case .accepted(let effects):
            guard members == nil || members == effects.map(\.memberID) else { return .unresolved }
            do {
                return .accepted(
                    try effects.map {
                        HistoryEffect(
                            memberID: $0.memberID,
                            undo: HistoryPayload(
                                family: operation, version: effectVersion,
                                data: try encodeEnvelope($0.undo, using: effectCodec)),
                            redo: HistoryPayload(
                                family: operation, version: effectVersion,
                                data: try encodeEnvelope($0.redo, using: effectCodec)), resources: $0.resources)
                    })
            } catch { return .unresolved }
        }
    }
    private func incompatible() -> HistoryFailure {
        HistoryFailure(.compatibility, stage: .delivery, disposition: .usable)
    }
}

final class HistorySessionActorHost<Handler: HistoryOperationHandler>: HistoryHost {
    let definition: HistorySessionOperationDefinition<Handler>
    init(definition: HistorySessionOperationDefinition<Handler>) { self.definition = definition }
    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        await definition.handler.deliverSession(delivery, definition: definition)
    }
    func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        await definition.handler.lookupSession(token, definition: definition)
    }
}

final class HistorySessionMainActorHost<Handler: MainActorHistoryOperationHandler>: HistoryHost {
    let definition: HistorySessionOperationDefinition<Handler>
    init(definition: HistorySessionOperationDefinition<Handler>) { self.definition = definition }
    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        await definition.handler.deliverSession(delivery, definition: definition)
    }
    func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        await definition.handler.lookupSession(token, definition: definition)
    }
}

extension HistoryOperationHandler {
    func encodeSessionCommands(
        _ values: [Command], definition: HistorySessionOperationDefinition<Self>,
        generation: UUID
    ) throws -> HistoryCommand {
        try definition.encode(values, generation: generation)
    }
    func deliverSession(
        _ delivery: HistoryDelivery,
        definition: HistorySessionOperationDefinition<Self>
    ) async -> HistoryHostOutcome {
        let value: HistoryTypedOutcome<Effect>
        do {
            let context = HistoryOperationContext(token: delivery.token, restorationOrigin: delivery.restorationOrigin)
            switch delivery.kind {
            case .command: value = await apply(try definition.commands(delivery.members), context: context)
            case .undo: value = await undo(try definition.effects(delivery.members), context: context)
            case .redo: value = await redo(try definition.effects(delivery.members), context: context)
            }
        } catch { return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable)) }
        return definition.outcome(value, members: delivery.members.map(\.id))
    }
    func lookupSession(
        _ token: HistoryToken,
        definition: HistorySessionOperationDefinition<Self>
    ) async -> HistoryHostOutcome {
        definition.outcome(await outcome(for: token))
    }
}

@MainActor extension MainActorHistoryOperationHandler {
    func encodeSessionCommands(
        _ values: [Command], definition: HistorySessionOperationDefinition<Self>,
        generation: UUID
    ) throws -> HistoryCommand {
        try definition.encode(values, generation: generation)
    }
    func deliverSession(
        _ delivery: HistoryDelivery,
        definition: HistorySessionOperationDefinition<Self>
    ) async -> HistoryHostOutcome {
        let value: HistoryTypedOutcome<Effect>
        do {
            let context = HistoryOperationContext(token: delivery.token, restorationOrigin: delivery.restorationOrigin)
            switch delivery.kind {
            case .command: value = await apply(try definition.commands(delivery.members), context: context)
            case .undo: value = await undo(try definition.effects(delivery.members), context: context)
            case .redo: value = await redo(try definition.effects(delivery.members), context: context)
            }
        } catch { return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable)) }
        return definition.outcome(value, members: delivery.members.map(\.id))
    }
    func lookupSession(
        _ token: HistoryToken,
        definition: HistorySessionOperationDefinition<Self>
    ) async -> HistoryHostOutcome {
        definition.outcome(await outcome(for: token))
    }
}
