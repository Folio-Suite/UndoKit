// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

extension HistoryNativeCoordinator {
    func capturePrerequisite() throws -> UUID? {
        guard !unknown, issue == nil else { throw issue ?? failure(.hostProtocol, suspended: true) }
        if fields.values.contains(where: \.requiresExplicitDecision) {
            throw failure(.unresolved, suspended: true)
        }
        guard let transaction else { return nil }
        try capture(transaction)
        return transaction.id
    }
    func settlePrerequisite(_ id: UUID, execute: @escaping @MainActor (HistoryCommand) async -> HistoryResult) async
        -> HistoryResult? {
        if let result = settled[id] { return result }
        guard let current = transaction, current.id == id, let state = fields[current.field] else { return nil }
        if state.composing { await withCheckedContinuation { compositionWaiters.append($0) } }
        guard !closing, !unknown, let currentTransaction = transaction, currentTransaction.id == id else {
            return .failure(failure(.cancelled))
        }
        do {
            try capture(currentTransaction)
            guard !state.composing else { return .failure(failure(.busy)) }
            try await prepareSettlement(state)
            guard let command = state.prepared else {
                try await refresh(state)
                retire(currentTransaction)
                return nil
            }
            try persist(state)
            let result = await execute(command)
            try await completeSettlement(result, transaction: currentTransaction, state: state)
            refreshAvailability()
            return result
        } catch {
            block(error)
            return .failure(issue!)
        }
    }
    private func prepareSettlement(_ state: HistoryNativeFieldState) async throws {
        if state.rejected {
            state.prepared = nil
            state.rejected = false
            state.liveRejectionEditable = false
            state.requiresDecision = false
            refreshAvailability()
        }
        guard state.prepared == nil else { return }
        guard try await state.declaration.read() == state.base else {
            throw failure(.identityConflict, suspended: true)
        }
        guard let generation = session.engine?.snapshot.generation else { throw failure(.missingHistory) }
        state.prepared = try await state.declaration.prepare(state.base, state.proposed, generation)
    }
    private func completeSettlement(
        _ result: HistoryResult, transaction: Transaction, state: HistoryNativeFieldState
    ) async throws {
        settled[transaction.id] = result
        switch result {
        case .accepted:
            do {
                try await refresh(state)
                retire(transaction)
            } catch { block(error) }
        case .rejected:
            state.rejected = true
            state.liveRejectionEditable =
                self.transaction?.id == transaction.id
                && adapters[transaction.attachment]?.value === transaction.adapter
            state.requiresDecision = true
            try persist(state)
        case .failure:
            state.liveRejectionEditable = false
            state.requiresDecision = true
            try persist(state)
        }
    }
    func admissionCompleted(_ result: HistoryResult) async {
        if case .accepted = result {
            for state in fields.values where state.prepared == nil && !state.requiresDecision {
                do { try await refresh(state) } catch {
                    block(error)
                    break
                }
            }
        }
        refreshAvailability()
    }
}
