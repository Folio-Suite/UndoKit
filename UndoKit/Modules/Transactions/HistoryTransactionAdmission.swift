// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryTransactionCoordinator {
    func requireIdle() throws {
        if store.writeFailed {
            throw HistoryFailure(.storage, stage: .admission, disposition: .suspended)
        }
        try activity.requireAdmission()
        guard !snapshot.isSuspended else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        let pending = try history.fetch(HistoryTransactionRecord.self, predicate: NSPredicate(
            format: "\(#keyPath(HistoryTransactionRecord.scopeKey)) == %@ AND " +
                "\(#keyPath(HistoryTransactionRecord.stage)) != %@ AND " +
                "\(#keyPath(HistoryTransactionRecord.stage)) != %@ AND " +
                "\(#keyPath(HistoryTransactionRecord.stage)) != %@",
            scope.uuidString, "accepted", "rejected", "cancelled"))
        guard pending.isEmpty else {
            throw HistoryFailure(.unresolved, stage: .admission, disposition: .suspended)
        }
    }
    /// One scoped fence for core recovery and any authoritative presentation read.
    func withReconciliation<Result>(
        _ operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        defer { updateSnapshot() }
        return try await activity.withExclusive(.reconciliation) {
            updateSnapshot()
            return try await operation()
        }
    }

    func withHostCallback<Result>(_ operation: @MainActor () async -> Result) async -> Result {
        let callbacks = HistoryHostCallbackContext.activeTransactions.union([ObjectIdentifier(self)])
        return await HistoryHostCallbackContext.$activeTransactions.withValue(callbacks) {
            await HistoryStore.$deliveringStores.withValue(
                HistoryStore.deliveringStores.union([ObjectIdentifier(store)])
            ) { await operation() }
        }
    }
}
