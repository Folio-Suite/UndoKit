// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

final class HistoryFamilyRouter: Sendable {
    typealias AtomicGroupExecutor = @Sendable (HistoryDelivery) async -> HistoryHostOutcome
    typealias AtomicOutcomeLookup = @Sendable (HistoryToken) async -> HistoryHostOutcome

    private let families: [String: any HistoryHost]
    private let atomicGroupExecutor: AtomicGroupExecutor?
    private let atomicOutcomeLookup: AtomicOutcomeLookup?

    /// Builds a family router. Mixed-family groups need both atomic callbacks.
    /// - Parameters:
    ///   - registrations: Unique, nonempty family names and their hosts.
    ///   - atomicGroupExecutor: Optional whole-group delivery callback.
    ///   - atomicOutcomeLookup: Matching authoritative recovery callback.
    /// - Throws: Invalid input for duplicate names or unmatched atomic callbacks.
    init(registrations: [(String, any HistoryHost)],
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

    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        let memberFamilies = Set(delivery.members.map(\.payload.family))
        guard !memberFamilies.isEmpty else {
            return .failure(HistoryFailure(.invalidInput, stage: .delivery, disposition: .usable))
        }
        // Per-family dispatch cannot manufacture atomicity across separate domain commits.
        // A mixed group therefore needs the host's explicit all-or-nothing executor and
        // matching durable outcome lookup, supplied together during registration.
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

    func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
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
