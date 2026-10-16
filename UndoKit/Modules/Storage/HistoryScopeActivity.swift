// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Scope admission and lifecycle share one owner; independent scopes may run
/// concurrently until their physical store establishes a maintenance fence.
@MainActor final class HistoryScopeActivity {
    enum Exclusive { case opening, reconciliation }
    private(set) var exclusive: Exclusive?
    private(set) var closing = false
    private(set) var closed = false
    let store: HistoryStore
    let scope: UUID

    init(store: HistoryStore, scope: UUID) {
        self.store = store
        self.scope = scope
    }

    var isActive: Bool { store.activity.isActive(scope: scope) }

    func requireAdmission(exclusive: Bool = true, fromCallback: Bool = false) throws {
        try store.activity.requireMutationAdmission(in: store)
        guard !closed, !closing, self.exclusive == nil,
              (!exclusive || !isActive),
              (fromCallback || !HistoryStore.deliveringStores.contains(ObjectIdentifier(store))) else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
    }

    private func beginExclusive(_ kind: Exclusive) throws -> HistoryActivityCompletion {
        // Scope-local opening and reconciliation may be requested from another
        // scope's host; only the caller's own active scope must be excluded.
        try requireAdmission(fromCallback: true)
        exclusive = kind
        let completion = store.activity.begin(scope: scope)
        return HistoryActivityCompletion { [self] in
            exclusive = nil
            completion.finish()
        }
    }

    func withExclusive<Result>(
        _ kind: Exclusive, operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        let completion = try beginExclusive(kind)
        defer { completion.finish() }
        return try await operation()
    }

    /// The FIFO has already admitted this work, so a later maintenance fence
    /// cannot reject its drain or publication refresh.
    func beginAdmitted() -> HistoryActivityCompletion { store.activity.begin(scope: scope) }

    func beginClosing() { closing = true }
    func didClose() { closed = true }
    func waitUntilIdle() async throws { try await store.activity.waitUntilIdle(scope: scope) }
}
