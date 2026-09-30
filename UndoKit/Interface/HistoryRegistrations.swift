// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Rebuilt from application code whenever the history store opens.
///
/// One registration represents one independently identified operation family.
/// Its handler actor owns all typed values; only encoded payloads and bounded
/// authoritative outcomes cross into UndoKit.
public struct HistoryOperationRegistration<Handler: HistoryTypedOperationHandler>: Sendable {
    public let identity: HistorySchemaIdentity
    public let commandCodec: HistoryCodec<Handler.Command>
    public let effectCodec: HistoryCodec<Handler.Effect>
    public let stateCodec: HistoryCodec<Handler.State>
    public let handler: Handler

    public init(identity: HistorySchemaIdentity,
                commandCodec: HistoryCodec<Handler.Command>,
                effectCodec: HistoryCodec<Handler.Effect>,
                stateCodec: HistoryCodec<Handler.State>,
                handler: Handler) {
        self.identity = identity
        self.commandCodec = commandCodec
        self.effectCodec = effectCodec
        self.stateCodec = stateCodec
        self.handler = handler
    }
}

/// Bridges one actor-owned typed operation family to the opaque history engine.
public final class HistoryRegisteredHost<Handler: HistoryOperationHandler>: HistoryHost {
    let registration: HistoryOperationRegistration<Handler>

    public init(_ registration: HistoryOperationRegistration<Handler>) {
        self.registration = registration
    }
}

/// Bridges a typed operation family whose domain models belong to `MainActor`.
@MainActor public final class MainActorHistoryRegisteredHost<Handler: MainActorHistoryOperationHandler>: HistoryHost {
    let registration: HistoryOperationRegistration<Handler>

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
