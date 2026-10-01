<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Retained-history module ownership

Accepted on 2026-09-30. One retained-history module per open History Scope owns
checkpoints, Recovery Plans, Retention Holds and consolidation. Keeping plan
protection and pruning together lets callers browse history without coordinating
its retention themselves. This completes the retained-history extraction deferred
by [ADR 0001](0001-transaction-module-ownership.md).

`HistoryEngine` implements two public main-actor capabilities: `HistoryReading`
for metadata, coherent native action names and reconstruction, and
`HistoryRetentionManaging` for checkpoints, holds and host-directed consolidation.
Reading can establish temporary Recovery Plan protection; it does not promise a
read-only physical store. Hosts continue to interpret payloads, reconstruct state
and submit restoration as a new Command.

Public contracts, documentation and small forwarding methods belong in
`Interface/`; the retained-history state and substantive implementation belong in
`Modules/RetainedHistory/`. `HistoryEngine` connects this owner to transactions
through narrow internal activity and protection operations. Only the
retained-history owner mutates its plan registry. Recording and generation
transitions still create their baseline checkpoints within their own atomic save.

Physical-store resource queries and cleanup remain store-scoped in
`Modules/Storage/`, because references and maintenance admission span all scopes.
This is an organizational refactor: preserve existing admission rules, plan
lifetime, cancellation, protection, atomicity, actor isolation and host policy.
The transaction protocol and stored representation remain unchanged.
