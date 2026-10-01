// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryTransactionCoordinator {
    func reconcile(_ transaction: NSManagedObject) async -> HistoryResult {
        switch transaction.string("stage") ?? "" {
        case "accepted":
            do {
                return .accepted(HistoryReceipt(token: try history.token(for: transaction),
                                                groupID: try transaction.uuid("groupID")))
            } catch { return .failure(HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)) }
        case "rejected":
            return .rejected
        case "cancelled":
            if let causeName = transaction.string("failureCause"),
               let stageName = transaction.string("failureStage"),
               let cause = HistoryFailureCause(rawValue: causeName),
               let stage = HistoryFailureStage(rawValue: stageName) {
                return .failure(HistoryFailure(cause, stage: stage, disposition: .usable,
                                               underlyingDescription: transaction.string("failureDescription")))
            }
            return .failure(HistoryFailure(.busy, stage: .reconciliation, disposition: .usable))
        case "prepared":
            transaction.setValue("cancelled", forKey: "stage")
            do { try history.saveContext() } catch { context.rollback() }
            return .failure(HistoryFailure(.busy, stage: .reconciliation, disposition: .usable))
        case "acceptancePending":
            return finalize(transaction, accepting: true)
        case "rejectionPending":
            return finalize(transaction, accepting: false)
        default:
            return await reconcileDelivered(transaction)
        }
    }

    private func finalize(_ transaction: NSManagedObject, accepting: Bool) -> HistoryResult {
        do {
            if !accepting { return try finalizeRejected(transaction) }
            return try transaction.bool("recordsAction")
                ? finalizeAccepted(transaction) : finalizeSessionAccepted(transaction)
        } catch {
            context.rollback()
            suspend()
            return .failure(HistoryFailure(.storage, stage: .finalization, disposition: .suspended))
        }
    }

    private func reconcileDelivered(_ transaction: NSManagedObject) async -> HistoryResult {
        do {
            let token = try history.token(for: transaction)
            let activeStores = HistoryStore.deliveringStores.union([ObjectIdentifier(store)])
            let outcome = await HistoryStore.$deliveringStores.withValue(activeStores) {
                let activeTransactions = HistoryHostCallbackContext.activeTransactions.union([ObjectIdentifier(self)])
                return await HistoryHostCallbackContext.$activeTransactions.withValue(activeTransactions) {
                    await host.outcome(for: token)
                }
            }
            return await finish(transactionKey: transaction.string("key") ?? "", outcome: outcome)
        } catch {
            suspend()
            return .failure(HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended))
        }
    }

    func reconcileOnOpen() async {
        do {
            let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryTransactionRecord")
            request.predicate = NSPredicate(format: "scopeKey == %@ AND stage != %@ AND stage != %@ AND stage != %@",
                                            scope.uuidString, "accepted", "rejected", "cancelled")
            request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: true)]
            for row in try context.fetch(request) { _ = await reconcile(row) }
            let remaining = try context.fetch(request)
            if remaining.isEmpty { unsuspend() }
        } catch { suspend() }
    }

    /// Rechecks a suspended transaction against authoritative host evidence.
    /// This never redelivers an operation whose delivery may have started.
    func reconcile() async -> HistoryResult? {
        if store.writeFailed {
            return .failure(HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended))
        }
        guard !isExecuting, !closed, !closing, !reconciling, !store.closing,
              !store.closed, !store.maintenance else {
            return .failure(HistoryFailure(.busy, stage: .reconciliation,
                                           disposition: closing ? .suspended : .usable))
        }
        reconciling = true
        defer { reconciling = false }
        do {
            let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryTransactionRecord")
            request.predicate = NSPredicate(format: "scopeKey == %@ AND stage != %@ AND stage != %@ AND stage != %@",
                                            scope.uuidString, "accepted", "rejected", "cancelled")
            request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: true)]
            guard let row = try context.fetch(request).first else {
                unsuspend()
                if sessionGroups.isEmpty { try releaseSessionReferences() }
                return nil
            }
            let result = await reconcile(row)
            if case .accepted = result, try context.fetch(request).isEmpty { unsuspend() }
            if case .rejected = result, try context.fetch(request).isEmpty { unsuspend() }
            if !snapshot.isSuspended && sessionGroups.isEmpty { try releaseSessionReferences() }
            return result
        } catch {
            return .failure(HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended))
        }
    }
}
