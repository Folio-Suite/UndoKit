// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Serializes physical-store maintenance across all registered scopes.
@MainActor final class HistoryStoreActivity {
    private(set) var maintenance = false

    /// Closing rejects waiting requests rather than draining them. Share only
    /// the store-wide exclusion rules with maintenance; the scope owns closure.
    func requireClosureAdmission(in store: HistoryStore) throws {
        guard !maintenance,
              !HistoryStore.deliveringStores.contains(ObjectIdentifier(store)) else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
    }

    /// Fences new mutation, waits for admitted work, and retains the fence
    /// through the host callback and any final history write.
    func withMaintenance<Result>(
        in store: HistoryStore,
        operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        guard store.access == .readWrite, !store.closed, !store.closing,
              !maintenance, !store.writeFailed,
              !HistoryStore.deliveringStores.contains(ObjectIdentifier(store)) else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        maintenance = true
        defer { maintenance = false }
        while store.engines.values.contains(where: { $0.transaction.isActive }) {
            if Task.isCancelled {
                throw HistoryFailure(.cancelled, stage: .admission, disposition: .usable)
            }
            await Task.yield()
        }
        if Task.isCancelled {
            throw HistoryFailure(.cancelled, stage: .admission, disposition: .usable)
        }
        return try await operation()
    }
}
