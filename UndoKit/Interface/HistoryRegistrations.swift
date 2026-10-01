// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Validated operation registration

/// Rebuilt from application code whenever the history store opens.
///
/// One registration represents one independently identified operation family.
/// Its handler actor owns all typed values; only encoded payloads and bounded
/// authoritative outcomes cross into UndoKit. Older decoders interpret retained
/// host payload versions without changing their stored bytes or fingerprints.
public struct HistoryOperationRegistration<Handler: HistoryTypedOperationHandler>: Sendable {
    public let identity: HistorySchemaIdentity
    public let commandCodec: HistoryCodec<Handler.Command>
    public let effectCodec: HistoryCodec<Handler.Effect>
    public let stateCodec: HistoryCodec<Handler.State>
    /// Decoders for earlier host payload versions. The current codecs above are used for all new writes.
    public let oldCommandCodecs: [Int: HistoryCodec<Handler.Command>]
    public let oldEffectCodecs: [Int: HistoryCodec<Handler.Effect>]
    public let oldStateCodecs: [Int: HistoryCodec<Handler.State>]
    public let handler: Handler

    /// Binds one handler to its codecs and derives their durable identities and settings.
    /// Version numbers belong to host payload schemas. Earlier read codecs are optional;
    /// they must name positive versions below the corresponding current write version.
    /// Codec identity and configuration come from the codecs themselves. Construction
    /// does not invoke their callbacks or validate host data. The registration retains
    /// its handler; host-owned adapters should avoid retaining their session in return.
    ///
    /// Rebuild the registration on reopening. Typed submission and state helpers must
    /// be invoked on this same handler instance; a different receiver is refused.
    /// - Parameters:
    ///   - operation: Stable host-defined family, independent of Swift type names.
    ///   - commandVersion: Current Command payload version.
    ///   - effectVersion: Current accepted-effect payload version.
    ///   - stateVersion: Current checkpoint payload version.
    ///   - commandCodec: Current Command encoder and decoder.
    ///   - effectCodec: Current compensation and reapplication encoder and decoder.
    ///   - stateCodec: Current checkpoint encoder and decoder.
    ///   - oldCommandCodecs: Explicit decoders for earlier Command versions.
    ///   - oldEffectCodecs: Explicit decoders for earlier accepted-effect versions.
    ///   - oldStateCodecs: Explicit decoders for earlier checkpoint versions.
    ///   - handler: Owner of typed values, semantic execution and authoritative receipts.
    /// - Throws: An admission `invalidInput` failure for an empty operation or codec identity,
    ///   a nonpositive current version, or an invalid earlier-version entry.
    public init(operation: String,
                commandVersion: Int = 1, effectVersion: Int = 1, stateVersion: Int = 1,
                commandCodec: HistoryCodec<Handler.Command>,
                effectCodec: HistoryCodec<Handler.Effect>,
                stateCodec: HistoryCodec<Handler.State>,
                oldCommandCodecs: [Int: HistoryCodec<Handler.Command>] = [:],
                oldEffectCodecs: [Int: HistoryCodec<Handler.Effect>] = [:],
                oldStateCodecs: [Int: HistoryCodec<Handler.State>] = [:],
                handler: Handler) throws {
        try HistoryRegistrationValidation.validate(operation: operation)
        try HistoryRegistrationValidation.validate(commandCodec, version: commandVersion, older: oldCommandCodecs)
        try HistoryRegistrationValidation.validate(effectCodec, version: effectVersion, older: oldEffectCodecs)
        try HistoryRegistrationValidation.validate(stateCodec, version: stateVersion, older: oldStateCodecs)
        self.identity = HistorySchemaIdentity(operation: operation,
            commandCodec: commandCodec.identifier, effectCodec: effectCodec.identifier,
            stateCodec: stateCodec.identifier,
            commandCodecConfiguration: commandCodec.configuration,
            effectCodecConfiguration: effectCodec.configuration,
            stateCodecConfiguration: stateCodec.configuration,
            commandVersion: commandVersion, effectVersion: effectVersion, stateVersion: stateVersion)
        self.commandCodec = commandCodec
        self.effectCodec = effectCodec
        self.stateCodec = stateCodec
        self.oldCommandCodecs = oldCommandCodecs
        self.oldEffectCodecs = oldEffectCodecs
        self.oldStateCodecs = oldStateCodecs
        self.handler = handler
    }
}

// MARK: - Actor host bridges

/// Bridges one actor-owned typed operation family to the opaque history engine.
public final class HistoryRegisteredHost<Handler: HistoryOperationHandler>: HistoryHost {
    let registration: HistoryOperationRegistration<Handler>

    /// Creates the opaque engine bridge for an actor-owned operation family.
    /// - Parameter registration: Host handler and its current and older codecs.
    public init(_ registration: HistoryOperationRegistration<Handler>) {
        self.registration = registration
    }

    /// Decodes and executes on the registered handler's actor, preserving whole-group acceptance.
    public func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        await registration.handler.deliverRegistered(delivery, registration: registration)
    }

    /// Looks up authoritative host evidence without applying the operation again.
    public func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        await registration.handler.lookupRegistered(token, registration: registration)
    }
}

/// Bridges a typed operation family whose domain models belong to `MainActor`.
@MainActor public final class MainActorHistoryRegisteredHost<Handler: MainActorHistoryOperationHandler>: HistoryHost {
    let registration: HistoryOperationRegistration<Handler>

    /// Creates the opaque engine bridge for a main-actor-owned operation family.
    /// - Parameter registration: Host handler and its current and older codecs.
    public init(_ registration: HistoryOperationRegistration<Handler>) {
        self.registration = registration
    }

    /// Decodes and executes on the registered handler's actor, preserving whole-group acceptance.
    public func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        await registration.handler.deliverRegistered(delivery, registration: registration)
    }

    /// Looks up authoritative host evidence without applying the operation again.
    public func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        await registration.handler.lookupRegistered(token, registration: registration)
    }
}
