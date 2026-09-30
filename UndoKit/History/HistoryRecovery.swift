// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryEngine {
    func reconcile(_ transaction: NSManagedObject) async -> HistoryResult {
        let stage = transaction.string("stage") ?? ""
        if stage == "accepted" {
            do {
                return .accepted(HistoryReceipt(token: try token(for: transaction),
                                                groupID: try transaction.uuid("groupID")))
            } catch { return .failure(HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)) }
        }
        if stage == "rejected" { return .rejected }
        if stage == "cancelled" {
            return .failure(HistoryFailure(.busy, stage: .reconciliation, disposition: .usable))
        }
        if stage == "prepared" {
            transaction.setValue("cancelled", forKey: "stage")
            do { try context.save() }
            catch { context.rollback() }
            return .failure(HistoryFailure(.busy, stage: .reconciliation, disposition: .usable))
        }
        if stage == "acceptancePending" {
            do { return try finalizeAccepted(transaction) }
            catch { context.rollback(); suspend(); return .failure(HistoryFailure(.storage, stage: .finalization, disposition: .suspended)) }
        }
        if stage == "rejectionPending" {
            do { return try finalizeRejected(transaction) }
            catch { context.rollback(); suspend(); return .failure(HistoryFailure(.storage, stage: .finalization, disposition: .suspended)) }
        }
        do {
            let token = try token(for: transaction)
            let outcome = await host.outcome(for: token)
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
    public func reconcile() async -> HistoryResult? {
        guard !draining, !closed, !closing, !reconciling else {
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
                return nil
            }
            let result = await reconcile(row)
            if case .accepted = result { unsuspend() }
            if case .rejected = result { unsuspend() }
            return result
        } catch {
            return .failure(HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended))
        }
    }
}
