<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Recovery probe evidence

## Final integrated result, 2026-09-29

**20/20 Swift Testing tests passed**, including five real SIGKILL boundaries.

- Design baseline: `52c498fcf7dc50b5c060820f217c957db74355f7`.
- Tested source: `4cf43e50c1b3c62045959cb156180f81e78f54ea`.
- Host: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Apple Swift 6.4.
- Command: `ruby UndoKit/prototypes/recovery/run.rb`.
- Compilation: Swift 6, complete concurrency checking, warnings as errors.
- Full runner exit: 0. Test phase: 0.291 seconds; total runner: 1.784 seconds.
- Sampled peak descendant RSS: 157,253,632 bytes; sampled build/fixture footprint:
  86,155,264 bytes. These watchdog observations are not allocation benchmarks.
- Normal run used default limits. A separate 1 MiB watchdog test returned 124
  and preserved diagnostics, as intended.

See [captured output and source hashes](evidence.md). Subsequent report-only commits
do not change those tested source bytes. The XCTest compatibility wrapper reports
zero tests; the Swift Testing run immediately following it executes all 20.

The five child modes terminate themselves with SIGKILL after preparation,
delivery-start recording, host acceptance, acceptance recording and finalization.
The parent verifies signal 9, opens fresh store connections and observes host
values, history Actions and availability. Every mode ultimately records host
value 7 and exactly one Action. The delivery-start/no-receipt case stays Unresolved
until a deliberately delayed host completion supplies evidence. That completion
is a fixture action, not a blind framework retry.

## Executed cases

- `acceptedCommandSurvivesReopenWithoutDuplicateDelivery` — passed.
- `preparationAndCancellationNeverChangeHost` — passed.
- `unknownOutcomeSuspendsOnlyItsScopeAndLaterReceiptRecovers` — passed.
- `hostAcceptedBeforeHistorySaveIsNeverAppliedTwice` — passed.
- `acceptedInverseAndRejectedInverseKeepEligibilityHonest` — passed.
- `groupMustHaveWholeAuthoritativeMemberEvidence` — passed.
- `rejectedOrdinaryCommandHasNoActionAndNoEffect` — passed.
- `failedHistoryFinalizationPreservesAcceptedEffectAcrossRepeatedReopens` — passed.
- `actualSIGKILLRecoveryAtTransactionBoundaries` — passed.
- `undoCannotSkipNewerAcceptedGroup` — passed.
- `wholeGroupInverseAndRejectionAreAtomicToCaller` — passed.
- `newOrdinaryCommandAfterUndoAbandonsRedoEligibility` — passed.
- `failedBoundarySavesNeverMistakeMissingReceiptForRejection` — passed.
- `failedAcceptanceRecordReconcilesWithoutRedelivery` — passed.
- `failedRejectionRecordCannotCreateAnActionOnReopen` — passed.
- `acceptedInverseFinalizesAfterReopenWithoutSecondHostDelivery` — passed.
- `rejectedInverseOutcomeSaveFailureKeepsRedoFenced` — passed.
- `incompleteInverseMemberPlanIsRefusedBeforeHostDelivery` — passed.
- `unresolvedScopeDoesNotStopIndependentAcceptedRecovery` — passed.
- `redoRequiresIdentityOfLatestCompensatingAction` — passed.

## Review and red/green evidence

The worker observed the first accepted-command/reopen test fail before its
implementation. Subsequent regression tests exposed actual defects before repairs:

- Undo could skip a newer group, producing host value 2 rather than 3.
- An incomplete one-member inverse could stand in for a two-member group.
- An unresolved scope prevented another scope's accepted effect from finalizing.
- Redo lacked a link to the latest compensation and could accept an unlinked plan.

The resulting tests now verify order, complete target membership, independent
recovery and immutable original/compensation links across repeated Undo/Redo and
reopening. Host delivery-attempt assertions prevent an idempotent host from
masking framework redelivery. These observations do not claim that every test's
failing revision was individually retained in Git.

### Standards

The initial independent review found no documented-standard violation and one
runner diagnostic-preservation concern. The runner and test fixture ownership
were repaired; re-review found no remaining standards regression.

### Spec

The independent review found incomplete inverse-plan validation, cross-scope
recovery blocking and insufficient recorded evidence. Re-review additionally
identified the absent Redo-to-compensation link. These were repaired with
regression tests and exact-source artifacts. Final read-only review of `aabbf80...4cf43e5` confirmed the remaining
Redo-link finding was addressed and found no material protocol regression.

## Scope and limitations

History uses a disposable programmatic Core Data model with normalized records
and string-key joins. Host state and its receipt are atomically replaced together
in a separate JSON file. This tests process interruption, not power loss or full
Core Data host integration. Managed objects remain private; the fixture has a
single main-actor writer. It does not prove production queue concurrency.

Fault injection rolls back at specified history-save boundaries; it is distinct
from inducing an actual filesystem or Core Data save error. Actual process kills
exercise the separate-store windows. Domain effects are synthetic integer changes;
malformed member evidence demonstrates suspension, not real domain repair.

The suite does not establish generation reset, retention/pruning, cancellation at
every production asynchronous boundary, native AppKit behavior, package copying,
migration/corruption recovery or scale. Those remain in the accepted proof plan.
A macOS 14 build target is not runtime evidence on that OS or Intel. No production
UndoKit API or Folio package was changed. This correctness run establishes no
latency percentile or production safety ceiling.

Maintainer acceptance is pending. #47 remains open.
