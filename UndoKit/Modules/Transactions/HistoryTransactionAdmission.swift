// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryTransactionCoordinator {
    func requireIdle() throws {
        if store.writeFailed {
            throw HistoryFailure(.storage, stage: .admission, disposition: .suspended)
        }
        guard store.access == .readWrite, !store.closed, !store.closing, !store.maintenance,
              !closed, !closing, !isActive,
              !snapshot.isSuspended,
              !HistoryStore.deliveringStores.contains(ObjectIdentifier(store)) else {
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
}
