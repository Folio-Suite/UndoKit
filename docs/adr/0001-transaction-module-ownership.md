<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Transaction module ownership

Accepted on 2026-09-30. Ordinary transaction operations use a narrow `@MainActor` `HistoryTransactions: AnyObject, Sendable`
protocol, while `HistoryEngine` remains the concrete scope owner. This keeps
editing clients on submission, Undo, Redo, reconciliation and one availability
callback, while the owner retains lifecycle and policy controls.

- **protocol surface:** expose `snapshot`, one `snapshotDidChange` callback,
  and distinct `submit`, `undo(expectedGeneration:)`, `redo(expectedGeneration:)`
  and `reconcile()` methods.
- **engine ownership:** retain the concrete `HistoryEngine` for lifecycle,
  recording, generation changes, retained-history operations and closure.
- **transaction coordination:** `Modules/Transactions/` owns FIFO admission,
  host delivery, durable finalization, reconciliation and session inverse behavior.
- **storage boundary:** `Modules/Storage/` owns persistence helpers and
  scoped store activity.
- **behavior:** preserve current transaction behavior and actor isolation;
  this boundary does not redesign actors or migrate stored data.
- **follow-up:** retained-history restructuring is recorded in
  [ADR 0002](0002-retained-history-module-ownership.md).
