// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Whole-group family routing

/// Routes independent operation families and requires an explicit whole-group
/// executor and matching outcome lookup before mixed-family commands can cross
/// the host boundary or participate in recovery.
public final class HistoryHostRegistry: HistoryHost {
    /// One all-or-nothing delivery across families; commit its token with the domain effect.
    public typealias AtomicGroupExecutor = @Sendable (HistoryDelivery) async -> HistoryHostOutcome
    /// Authoritative lookup of that same atomic group token without repeating its effects.
    public typealias AtomicOutcomeLookup = @Sendable (HistoryToken) async -> HistoryHostOutcome

    private let router: HistoryFamilyRouter

    /// Builds a router from unique, nonempty family identities.
    /// Mixed-family groups require both atomic callbacks. Neither callback may
    /// implement a group by committing each family independently.
    /// - Throws: An admission `invalidInput` failure for duplicate/empty families or unmatched callbacks.
    public init(registrations: [(String, any HistoryHost)],
                atomicGroupExecutor: AtomicGroupExecutor? = nil,
                atomicOutcomeLookup: AtomicOutcomeLookup? = nil) throws {
        router = try HistoryFamilyRouter(registrations: registrations,
            atomicGroupExecutor: atomicGroupExecutor, atomicOutcomeLookup: atomicOutcomeLookup)
    }

    /// Routes one whole delivery, refusing unsupported or uncoordinated mixed-family groups.
    public func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        await router.deliver(delivery)
    }

    /// Resolves through authoritative lookup; conflicting family outcomes remain unresolved.
    public func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        await router.outcome(for: token)
    }
}
