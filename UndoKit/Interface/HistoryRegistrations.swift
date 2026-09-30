// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

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

    /// Registers current write codecs and explicit older read codecs for a host actor.
    /// Codec callbacks run on the handler's actor. Unknown versions fail before
    /// semantic application; old-version entries are only read when below the
    /// corresponding current version.
    /// - Parameters:
    ///   - identity: Stable family and current write versions and codec identities.
    ///   - commandCodec: Current Command write and read codec.
    ///   - effectCodec: Current effect write and read codec.
    ///   - stateCodec: Current checkpoint state write and read codec.
    ///   - oldCommandCodecs: Earlier Command versions the host can still read.
    ///   - oldEffectCodecs: Earlier effect versions the host can still read for Undo and Redo.
    ///   - oldStateCodecs: Earlier checkpoint state versions the host can still read.
    ///   - handler: Actor-owned domain behavior and authoritative outcome lookup.
    public init(identity: HistorySchemaIdentity,
                commandCodec: HistoryCodec<Handler.Command>,
                effectCodec: HistoryCodec<Handler.Effect>,
                stateCodec: HistoryCodec<Handler.State>,
                oldCommandCodecs: [Int: HistoryCodec<Handler.Command>] = [:],
                oldEffectCodecs: [Int: HistoryCodec<Handler.Effect>] = [:],
                oldStateCodecs: [Int: HistoryCodec<Handler.State>] = [:],
                handler: Handler) {
        self.identity = identity
        self.commandCodec = commandCodec
        self.effectCodec = effectCodec
        self.stateCodec = stateCodec
        self.oldCommandCodecs = oldCommandCodecs
        self.oldEffectCodecs = oldEffectCodecs
        self.oldStateCodecs = oldStateCodecs
        self.handler = handler
    }

    func commandDecoder(for version: Int) -> HistoryCodec<Handler.Command>? {
        decoder(for: version, currentVersion: identity.commandVersion,
                current: commandCodec, old: oldCommandCodecs)
    }

    func effectDecoder(for version: Int) -> HistoryCodec<Handler.Effect>? {
        decoder(for: version, currentVersion: identity.effectVersion,
                current: effectCodec, old: oldEffectCodecs)
    }

    func stateDecoder(for version: Int) -> HistoryCodec<Handler.State>? {
        decoder(for: version, currentVersion: identity.stateVersion,
                current: stateCodec, old: oldStateCodecs)
    }

    private func decoder<Value>(for version: Int, currentVersion: Int,
                                current: HistoryCodec<Value>, old: [Int: HistoryCodec<Value>]) -> HistoryCodec<Value>? {
        guard version > 0 else { return nil }
        if version == currentVersion { return current }
        guard version < currentVersion else { return nil }
        return old[version]
    }

    func decodeCommands(_ members: [HistoryMember]) throws -> [(UUID, Handler.Command)] {
        try members.map { member in
            guard let codec = commandDecoder(for: member.payload.version) else {
                throw HistoryFailure(.compatibility, stage: .delivery, disposition: .usable)
            }
            return (member.id, try decodeEnvelope(member.payload.data, using: codec, stage: .delivery))
        }
    }

    func decodeEffects(_ members: [HistoryMember]) throws -> [(UUID, Handler.Effect)] {
        try members.map { member in
            guard let codec = effectDecoder(for: member.payload.version) else {
                throw HistoryFailure(.compatibility, stage: .delivery, disposition: .usable)
            }
            return (member.id, try decodeEnvelope(member.payload.data, using: codec, stage: .delivery))
        }
    }

    func encodeEffects(_ effects: [HistoryTypedEffect<Handler.Effect>]) throws -> [HistoryEffect] {
        try effects.map { effect in
            HistoryEffect(
                memberID: effect.memberID,
                undo: HistoryPayload(family: identity.operation, version: identity.effectVersion,
                                     data: try encodeEnvelope(effect.undo, using: effectCodec)),
                redo: HistoryPayload(family: identity.operation, version: identity.effectVersion,
                                     data: try encodeEnvelope(effect.redo, using: effectCodec))
            )
        }
    }
}

/// Bridges one actor-owned typed operation family to the opaque history engine.
public final class HistoryRegisteredHost<Handler: HistoryOperationHandler>: HistoryHost {
    let registration: HistoryOperationRegistration<Handler>

    /// Creates the opaque engine bridge for an actor-owned operation family.
    /// - Parameter registration: Host handler and its current and older codecs.
    public init(_ registration: HistoryOperationRegistration<Handler>) {
        self.registration = registration
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
}

/// Routes independent operation families and requires an explicit whole-group
/// executor and matching outcome lookup before mixed-family commands can cross
/// the host boundary or participate in recovery.
public final class HistoryHostRegistry: HistoryHost {
    public typealias AtomicGroupExecutor = @Sendable (HistoryDelivery) async -> HistoryHostOutcome
    public typealias AtomicOutcomeLookup = @Sendable (HistoryToken) async -> HistoryHostOutcome

    private let families: [String: any HistoryHost]
    private let atomicGroupExecutor: AtomicGroupExecutor?
    private let atomicOutcomeLookup: AtomicOutcomeLookup?

    /// Builds a family router. Mixed-family groups need both atomic callbacks.
    /// - Parameters:
    ///   - registrations: Unique, nonempty family names and their hosts.
    ///   - atomicGroupExecutor: Optional whole-group delivery callback.
    ///   - atomicOutcomeLookup: Matching authoritative recovery callback.
    /// - Throws: Invalid input for duplicate names or unmatched atomic callbacks.
    public init(registrations: [(String, any HistoryHost)],
                atomicGroupExecutor: AtomicGroupExecutor? = nil,
                atomicOutcomeLookup: AtomicOutcomeLookup? = nil) throws {
        guard (atomicGroupExecutor == nil) == (atomicOutcomeLookup == nil) else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        var built: [String: any HistoryHost] = [:]
        for (family, host) in registrations {
            guard !family.isEmpty, built[family] == nil else {
                throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
            }
            built[family] = host
        }
        self.families = built
        self.atomicGroupExecutor = atomicGroupExecutor
        self.atomicOutcomeLookup = atomicOutcomeLookup
    }

    public func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        let memberFamilies = Set(delivery.members.map(\.payload.family))
        guard !memberFamilies.isEmpty else {
            return .failure(HistoryFailure(.invalidInput, stage: .delivery, disposition: .usable))
        }
        guard memberFamilies.count == 1 else {
            guard let atomicGroupExecutor else {
                return .failure(HistoryFailure(.invalidInput, stage: .delivery, disposition: .usable))
            }
            return await atomicGroupExecutor(delivery)
        }
        guard let family = memberFamilies.first, let host = families[family] else {
            return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable))
        }
        return await host.deliver(delivery)
    }

    public func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        if let atomicOutcomeLookup {
            let outcome = await atomicOutcomeLookup(token)
            switch outcome {
            case .accepted, .rejected, .failure:
                return outcome
            case .unresolved:
                break
            }
        }
        var terminal: HistoryHostOutcome?
        for host in families.values {
            let outcome = await host.outcome(for: token)
            switch outcome {
            case .unresolved:
                continue
            case .failure(let failure) where failure.disposition == .usable:
                continue
            case .accepted, .rejected, .failure:
                guard terminal == nil else { return .unresolved }
                terminal = outcome
            }
        }
        return terminal ?? .unresolved
    }
}
