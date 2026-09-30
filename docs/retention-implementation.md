<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Retention implementation and measured case

The public retention types and methods are in `Interface/HistoryRetention.swift`,
`HistoryRetentionHolds.swift`, `HistoryConsolidation.swift`, and
`HistoryRetentionResources.swift`. Internal protection and mutation helpers live
in `Modules/Retention/`.

State holds preserve checkpoint snapshots and their resource references. Detail
holds preserve their complete-group interval. Neither extends ordinary Undo depth.
Releasing one hold leaves overlapping holds intact. Holds survive store closure.

`consolidateHistory(through:policy:)` uses a host-authored checkpoint as the state
boundary. It never computes document state. Each call removes at most one read
page of eligible groups and checkpoints. Repeat while `hasMore` is true, allowing
the app to schedule or cancel between calls. The target is advisory when protected
material exceeds it. Keep desired older checkpoints explicitly in the policy.
Ordinary Undo/Redo, holds, current structural position, required related groups,
and live recovery plans remain protected. Deleted transitions leave explicit gaps;
compact accepted receipts still deduplicate old command identities.

Resource identities consist of a retention-store UUID, nonempty object key and
optional nonempty version key. `nil` means unversioned. UndoKit preserves opaque
references; it does not access resource files. `requiredObjects` aggregates all
scopes in this physical history store. During `withRequiredObjects`, admissions
are fenced while the host pages requirements and performs its own atomic cleanup.
The host must also protect objects required by current content or other physical
history stores. An unsuccessful cleanup remains pending for retry.

## Measured production-engine case

The guarded release runner completed 10,000 accepted groups on the maintainer's
Mac on 2026-09-30 at source `f2c4948a347b580e8330590ff3148a6991ce0240`:

| Phase | Result |
| --- | --- |
| Fixture construction | 327.37 seconds |
| Far-back reconstruction | 9,999 transitions in 2.030 seconds |
| Divergent reconstruction | 101 transitions in 0.021 seconds |
| Consolidation | 9,803 groups removed in 154 bounded passes, 13.35 seconds |
| Overall including build | 363.20 seconds |
| Peak sampled descendant RSS | 814,186,496 bytes |
| Peak sampled owned footprint | 129,417,216 bytes |

The fixture verified unchanged current state, checkpoint recovery, and accepted
retry identity after pruning. The later missing-transition integrity and empty
version-key corrections are covered by focused tests. This measurement predates
those corrections and does not qualify 100,000 production groups or large host
payloads. Run `ruby scripts/check-undokit-scale.rb 10000` to reproduce under the
same 2 GiB memory, 12 GiB temporary storage, 20 GiB free-disk and ten-minute guards.
