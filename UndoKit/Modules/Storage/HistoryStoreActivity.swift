// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// One admitted lifetime. Completion is idempotent, including late encoding or
/// cancellation callbacks for an already completed Command reservation.
@MainActor final class HistoryActivityCompletion {
    private var completion: (() -> Void)?

    init(_ completion: @escaping () -> Void) { self.completion = completion }

    func finish() {
        let completion = self.completion
        self.completion = nil
        completion?()
    }
}

/// Owns physical-store exclusion and notification for all admitted scope work.
/// The Command FIFO remains exclusively owned by the transaction coordinator.
@MainActor final class HistoryStoreActivity {
    private(set) var maintenance = false
    private var activities: [UUID: UUID] = [:]
    private struct Waiter {
        let scope: UUID?
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [UUID: Waiter] = [:]

    func isActive(scope: UUID? = nil) -> Bool {
        if let scope { return activities.values.contains(scope) }
        return !activities.isEmpty
    }

    func requireMutationAdmission(in store: HistoryStore) throws {
        guard store.access == .readWrite, !store.closed, !store.closing,
              !maintenance, !store.writeFailed else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
    }

    /// Closure rejects waiting Commands; maintenance instead drains reservations.
    func requireClosureAdmission(in store: HistoryStore) throws {
        guard !maintenance,
              !HistoryStore.deliveringStores.contains(ObjectIdentifier(store)) else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
    }

    func begin(scope: UUID) -> HistoryActivityCompletion {
        let id = UUID()
        activities[id] = scope
        return HistoryActivityCompletion { [self] in
            activities.removeValue(forKey: id)
            let ready = waiters.filter { !isActive(scope: $0.value.scope) }
            for (id, waiter) in ready {
                waiters.removeValue(forKey: id)
                waiter.continuation.resume()
            }
        }
    }

    /// Checking and registering happen in one actor turn. Cancellation removes
    /// only its own waiter, even if completion has already resumed that waiter.
    func waitUntilIdle(scope: UUID? = nil, cancellable: Bool = false) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancellable && Task.isCancelled {
                    continuation.resume(throwing: cancelled())
                } else if !isActive(scope: scope) {
                    continuation.resume()
                } else {
                    waiters[id] = Waiter(scope: scope, continuation: continuation)
                }
            }
        } onCancel: {
            guard cancellable else { return }
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.continuation.resume(throwing: self.cancelled())
            }
        }
    }

    private func cancelled() -> HistoryFailure {
        HistoryFailure(.cancelled, stage: .admission, disposition: .usable)
    }

    /// Fence new mutation, await completion notifications for already admitted
    /// work, and retain exclusion through capture and final history writes.
    func withMaintenance<Result>(
        in store: HistoryStore,
        operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        try requireMutationAdmission(in: store)
        try requireClosureAdmission(in: store)
        maintenance = true
        defer { maintenance = false }
        try await waitUntilIdle(cancellable: true)
        if Task.isCancelled { throw cancelled() }
        return try await operation()
    }
}
