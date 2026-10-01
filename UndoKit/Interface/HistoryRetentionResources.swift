// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

extension HistoryStore {
    // MARK: - Required objects

    /// Distinct required objects are aggregated across all scopes. The caller
    /// pages by the last returned reference; each page is capped by maxReadPage.
    /// Ordering is lexicographic by canonical object key, then version key;
    /// an unversioned (`nil`) key sorts as the empty stored value. Pass the
    /// returned `nextCursor` to continue. An explicit empty version key is
    /// invalid on input, so cursors cannot conflate two object identities.
    /// Counts and pages are committed snapshots, not a stable sequence across
    /// concurrent writes. Use `withRequiredObjects(in:cleanup:)` for destructive
    /// host cleanup. Read-only sessions may call this method. A large required
    /// set needs multiple pages and a count query for each distinct object.
    public func requiredObjects(in retentionStore: UUID,
                                after cursor: HistoryObjectReference? = nil,
                                limit: Int) throws -> HistoryRequiredObjectPage {
        try requiredObjectsForRetention(in: retentionStore, after: cursor, limit: limit)
    }

    // MARK: - Host cleanup

    /// Whether a prior pruning step removed references and host cleanup is due.
    public func cleanupPending(for retentionStore: UUID) throws -> Bool {
        try isRetentionCleanupPending(for: retentionStore)
    }

    /// Fences admissions across all scopes while the host removes unrequired
    /// objects in its own atomic transaction. A failed callback leaves durable
    /// retry evidence, and the host can page required objects within the fence.
    /// The callback must perform its own durable cleanup; UndoKit never deletes
    /// host objects. It may read required-object pages but cannot re-enter
    /// history mutation or another maintenance operation on this store. This
    /// method waits for active deliveries, refuses unresolved transactions in
    /// any scope, and rejects read-only or failed writable sessions. Cancellation
    /// before the callback leaves the cleanup marker intact. Once the callback
    /// succeeds, cancellation cannot retract host cleanup; UndoKit clears the
    /// marker, or keeps it for retry if its own final save fails.
    public func withRequiredObjects(
        in retentionStore: UUID,
        cleanup: @MainActor (HistoryStore) async throws -> Void
    ) async throws {
        try await performRequiredObjectCleanup(in: retentionStore, cleanup: cleanup)
    }
}
