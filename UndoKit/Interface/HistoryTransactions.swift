// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Ordinary transaction use for one open History Scope.
///
/// The owner opens and retains a concrete `HistoryEngine`, then passes it through
/// this interface to editing code. The owner also manages recording, generation
/// changes, retained history and closure. Host domain values remain on their
/// actor; only opaque history values cross this interface.
///
/// Requests are admitted in FIFO order within the scope. Successful completion
/// follows durable history finalization, not merely host execution. Cancellation
/// before preparation removes a waiting request; after possible delivery,
/// authoritative outcome reconciliation must continue. A host callback must not
/// await another request to its own scope; such reentry is refused.
@MainActor public protocol HistoryTransactions: AnyObject, Sendable {
    /// Coherent availability, including scope, generation and monotonic version.
    /// Pending admission does not establish a durable accepted outcome.
    var snapshot: HistorySnapshot { get }

    /// One host-owned availability observer, invoked on the main actor.
    /// Read `snapshot` for the initial value. Await each operation for its result;
    /// this callback reports availability changes, not transaction completion.
    var snapshotDidChange: (@MainActor (HistorySnapshot) -> Void)? { get set }

    /// Submits a whole semantic Command. Retrying unresolved intent keeps its ID
    /// and fingerprint. Accepted results contain a finalized history receipt.
    func submit(_ command: HistoryCommand) async -> HistoryResult

    /// Reverses the latest eligible complete Undo Group through one host delivery.
    /// Bind to the observed generation to reject commands from retired continuity.
    func undo(expectedGeneration: UUID?) async -> HistoryResult

    /// Reapplies the next eligible complete Undo Group through one host delivery.
    /// Bind to the observed generation to reject commands from retired continuity.
    func redo(expectedGeneration: UUID?) async -> HistoryResult

    /// Consults authoritative host evidence without repeating possible delivery.
    /// Nil means no unresolved transaction remained to reconcile. Inspect the
    /// result and snapshot before resuming host operations after suspension.
    func reconcile() async -> HistoryResult?
}
