<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Historical reconstruction

`Interface/HistoryReconstruction.swift` defines handles and lightweight records.
`Interface/HistoryReading.swift` exposes bounded reads, coherent identity and
host-resolved native labels. Their implementation and temporary plan protection
live together in `Modules/RetainedHistory/`.

## Host responsibility

A host opts into `.acceptedEffects` only if its accepted Undo and Redo payloads
can reconstruct complete state transitions. UndoKit cannot verify that semantic
promise. Hosts needing other reconstruction evidence should supply complete
checkpoint snapshots. Capture a coherent domain baseline before asking for a
`.current` plan; do not interleave an unrelated domain change with that capture.

Plans traverse accepted transitions chronologically, including accepted Undo and
Redo operations. This preserves displaced continuations without guessing at
payload meaning. A reverse plan visits newest groups first and applies members in
reverse ordinal order. A checkpoint-source plan visits groups and members forward.
A checkpoint target uses that checkpoint as its complete baseline and needs no
transition reads.

## Bounded read loop

1. Create a plan with `beginRecoveryPlan(from:to:using:)`.
2. For a checkpoint source, fetch `recoveryCheckpoint(_:)`.
3. Fetch `recoveryPage(_:after:limit:)`, then each step's individual
   `recoveryMaterial(_:groupID:ordinal:)`. Continue with `nextCursor` until nil.
4. Reconstruct and validate an isolated host state. No history read invokes the
   host's command delivery or moves the live Undo position.
5. Release the plan, including on failure. Explicit cancellation and closing the
   scope invalidate the handle; a cancelled task's next read also releases it.
6. If the user adopts the result, submit a new host command with
   `restorationOrigin`. That command remains undoable back to the displaced state.

A plan records scope, generation and committed version and fixes its sequence
bounds. Later accepted commands cannot extend it. The engine limits concurrent
plans and protects their material during their session lifetime. Missing targets,
explicit retained gaps, or missing/corrupt payloads refuse reconstruction.
Persisted predecessor sequences and source anchors detect missing interior or
latest transitions; checkpoint and rejected-request sequence gaps remain valid.

## Presentation

Attach an optional opaque `presentation` payload to a submitted command (at most
4 KiB). Fetch it by group identity without reconstruction. The host decodes it;
UndoKit does not interpret labels, thumbnails or domain identifiers.
`nativeActionNames(resolve:)` returns host-resolved names and the matching native
availability snapshot in one actor turn. `readIdentity()` identifies a committed
scope view independently of the native availability version.

## Verification and scale

The ordinary tests cover divergent reconstruction, restoration followed by Undo,
checkpoint baselines, paging, metadata, missing targets, cancellation and plan
lifetime. Retention adds tests for explicit gaps and active-plan preservation.

Run `ruby scripts/check-undokit-scale.rb 10000` for an opt-in production-engine
fixture; 100,000 is the upper supported runner size. The runner enforces the
accepted laptop safeguards: 2 GiB combined descendant RSS, 12 GiB owned temporary
storage, 20 GiB free disk, and ten minutes including fixture construction. One
runner holds a machine-local lock. A budget stop is reported as incomplete evidence.
The fixture uses a process-local host to isolate history-engine costs; it does not
measure host durability or full document reconstruction cost. Normal tests skip
this fixture. Existing prototype measurements remain separate evidence.

### Measured production-engine case

On the maintainer's Mac on 2026-09-30, the guarded 10,000-group release case
completed at source `25e7bbd279e57bfea0d367616b7b0526aebed143`:

| Phase | Result |
| --- | --- |
| Fixture construction | 10,000 accepted groups in 320.25 seconds |
| Far-back read | 9,999 transitions in 1.735 seconds, reconstructed state verified |
| Divergent read | 101 transitions in 0.019 seconds, displaced state verified |
| Overall including build | 341.64 seconds |
| Peak sampled descendant RSS | 733,822,976 bytes |
| Peak sampled owned footprint | 128,012,288 bytes |

The later lifecycle rebase changes failure handling and closure; its functional
suite is rerun separately. This case does not qualify 100,000 production groups,
large payloads, host database throughput, or document UI responsiveness. The runner
accepts larger opt-in cases under the same safeguards.
