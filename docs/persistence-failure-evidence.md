<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Production persistence-failure evidence

This record implements the bounded injected-error and graceful close/reopen scope
of [issue #15](https://github.com/Folio-Suite/UndoKit/issues/15), under the
[issue #8 acceptance resolution](https://github.com/Folio-Suite/UndoKit/issues/8#issuecomment-6104499789)
and [issue #6 compatibility resolution](https://github.com/Folio-Suite/UndoKit/issues/6#issuecomment-6104176471).
It supplies focused development evidence, not release qualification.

## Setup and identity

Observed on 2026-10-11 in the development worktree based on
`6c8eb91c5d3fdf7d89473a6ce0bf769bbee1f295`, with uncommitted preview-foundation
changes. macOS `27.0.1` (`26A434`), arm64, Apple Swift `6.4`
(`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`). The exact final commit and
candidate artifact identity must be recorded during candidate qualification;
this worktree observation is not that seal.

The [focused suite](../UndoKitTests/HistoryPersistenceFailureTests.swift) uses
production `HistoryStore`/`HistoryEngine` operations and a
[separately persisted host](../UndoKitTests/PersistenceEvidenceHost.swift).
State, application/delivery counts and authoritative complete-group receipts are
written together by atomic JSON replacement in the host's store. New host
instances load that state after each failure. Receipts retain Command, History
Scope, History Generation, sequence and ordered member effect identities.

Debug-only task-local selectors inject an error immediately before the real
scope-context save, after production admission and capacity preflight, or after
Core Data has created the copy destination. Save injection selects durable
preparation, delivery-start, host-evidence or finalization boundaries by the
changed transaction stage; retention injection runs at its save boundary.
Injected saves pass through the normal rollback and physical-store write-failure
handling. The selectors and their checks are absent from Release builds. They
are internal test controls; tests assert public results, retained-history reads,
required-object references and independently persisted host/resource bytes.
No internal record query is used as a success oracle.

## Focused results

```sh
swift test --scratch-path DerivedData/PersistenceTests \
  --filter HistoryPersistenceFailureTests
swift test --configuration release --scratch-path DerivedData/PersistenceTests \
  --filter 'History(PersistenceFailure|OpeningCompatibility)Tests'
```

Debug: **9 tests passed**, including both evidence/finalization variants of
accepted and rejected outcomes and both missing-codec/resource variants.
Release: **11 tests passed**: nine opening/compatibility tests and two ordinary
persistence-preservation tests. The seven tests requiring Debug injection are
intentionally absent in Release. No full suite is claimed by these focused runs;
the batch integration run records that separately.

| Focused test | Observed behavior |
| --- | --- |
| `testSaveFailureAfterPreflightPreservesHostAndAllowsFreshSession` | An admitted bounded Command fails at preparation save. The live store suspends; no host delivery, receipt or group exists. Resource bytes survive, and a fresh session accepts the same Command once. |
| `testFailedDeliveryFenceNeverDeliversPreparedCommandOnReopen` | Saving the delivery-start fence fails after preparation is durable. The failure reports preparation. Graceful reopen cancels the undelivered record and never delivers that Command. Its cancelled preparation identity is not silently reused. |
| `testAcceptedOutcomesRecoverWholeGroupWithoutRepeatingHostEffects` | A separately persisted two-member accepted effect survives failure before acceptance evidence is saved and failure after evidence is durable but before final group save. Reopen reconstructs one complete group, retains Command/token identity, and does not alter the host receipt or repeat delivery. Whole-group Undo returns host state to 0. |
| `testRejectedOutcomesRecoverWithoutAnActionOrDuplicateDelivery` | Durable rejection survives failure before rejection evidence and before final rejection save. Reopen retires pending evidence without an Action; retry returns rejection with unchanged host bytes and one delivery. |
| `testCopyBoundaryFailurePreservesSourceAndDoesNotOfferPartialTarget` | The destination exists when the physical copy fails. No host capture callback runs, no database/journal target remains, source history and host/resource bytes survive, the maintenance fence releases, and a subsequent coherent copy and source reopen succeed. |
| `testCopyRefusesExistingDestinationJournalWithoutReplacingIt` | A preexisting destination WAL is preserved; copy refuses the occupied artifact set rather than mixing it into a new destination. |
| `testFailedConsolidationPreservesHistoryHoldsAndRecoveryResources` | A save error after retention changes rolls back both removable and protected history. Durable detail hold, checkpoint/resource references and host/resource bytes survive reopen. An active Recovery Plan then protects its interval; releasing the plan permits only the unheld eligible group to prune. |
| `testUnavailableCodecOrResourceProtectsPendingEvidenceUntilRestored` | After failed acceptance-evidence persistence, unavailable host decoding or a resource blocks authoritative lookup and reports compatibility with Suspension. Pending evidence prevents cleanup callback execution. Restoring the prerequisite and reopening reconciles one group without host replay or byte changes. |
| `testBoundedLimitRefusalPreservesHistoryHostReceiptsAndResourceBytes` | Oversized payload and too many members refuse at admission with capacity/usable. Accepted history, Undo availability, authoritative receipt and resource bytes remain unchanged. |

The first save test was observed red before the physical injection was wired:
submission accepted and host state changed instead of returning the requested
save failure. The copy test likewise went red before its physical selector was
wired. A separate public regression exposed the incorrect delivery-fence failure
classification (`finalization` instead of `preparation`) and passed after the
minimal production correction.

The production copy boundary now refuses any preexisting destination database,
WAL, shared-memory or rollback journal and cleans the owned destination artifact
set on failure. If cleanup itself fails, the error reports that condition;
recovery of remaining artifacts is host-owned. No completed copy is offered to
the capture callback until preparation succeeds.

## Complementary existing coverage

These existing tests supply distinct obligations and are included in the batch's
full-suite validation; their existence alone is not a fresh pass here:

- `HistoryTypedHostTests.testActorReopenReadsOldHostVersionsWithoutRewritingPayloads`
  and `testMainActorReopenReadsOldHostVersionsAndRefusesUnknown`, implemented in
  [versioning tests](../UndoKitTests/HistoryTypedHostVersioningTests.swift), exercise
  the production registered-codec adapter. Missing old effect decoders and
  unknown versions refuse without losing retained payload/checkpoint material;
  supplied old decoders allow later use. The new durable-host fixture checks
  missing prerequisites during outcome recovery separately.
- [Retention tests](../UndoKitTests/HistoryRetentionTests.swift):
  `testStateAndOverlappingDetailHoldsSurviveReleaseAndReopen`,
  `testActiveRecoveryPlanProtectsReverseTargetAndReleaseAllowsGap`,
  `testSharedResourcesAndCleanupRetryAcrossScopes` and
  `testCleanupWaitsForOtherScopeToReconcileAcceptedOutcome` cover durable holds,
  recovery protection and multi-scope resource cleanup ordering.
- [Recording tests](../UndoKitTests/HistoryRecordingTests.swift):
  `testOffSessionProtectsRequiredObjectsUntilSessionCloses` and
  `testUnresolvedResetRequiresQuarantineAndPreservesEvidence` cover session-only
  dependency protection and explicit generation recovery boundaries.
- [Maintenance tests](../UndoKitTests/HistoryStoreMaintenanceTests.swift):
  `testFailedCaptureReleasesMaintenanceAndPreservesCompletedCopy` distinguishes
  a host capture callback failure, which leaves a completed copy for the host,
  from the new physical copy failure, which removes the incomplete target.
- [Opening compatibility tests](../UndoKitTests/HistoryOpeningCompatibilityTests.swift)
  cover missing, corrupt, unregistered, incompatible and hypothetical newer-model
  stores, identity mismatch and byte-preserving read-only inspection.

## Qualification limits

These errors exercise production persistence paths and graceful closure/reopen.
They do not certify actual disk exhaustion, abrupt termination, cold filesystem
cache behavior, forced process relaunch recovery or every possible system I/O
error. Temporary resource unavailability is arranged by preserving the resource
at a separate path, not deleting retained bytes. Host interpretation and outcome
availability remain host-owned; opaque UndoKit storage cannot invent codecs or
missing evidence.

The record does not supply Intel runtime, iOS hardware/file-protection lifecycle,
floor/current platform matrix, installed binary/resource lookup, native routing,
10,000-group scale or final candidate signing/sealing evidence. Those remain
separate gates. No schema change, supported migration or `0.1.0` upgrade promise
is introduced by these tests.
