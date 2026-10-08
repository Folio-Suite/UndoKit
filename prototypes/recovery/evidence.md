<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Captured recovery run, 2026-09-29

Tested source: `4cf43e50c1b3c62045959cb156180f81e78f54ea`.
The following output is the full final runner output; its JSON report provides
exact source hashes. Successful scratch stores were cleaned after verification.

## Runner output

```text
Recovery probe limits: {"timeout_seconds":180,"memory_bytes":2147483648,"disk_bytes":12884901888,"free_floor_bytes":21474836480}
Building for debugging...
Build complete! (0.21 sec)
Test Suite 'All tests' started at 2026-09-29 15:43:01.074.
Test Suite 'All tests' passed at 2026-09-29 15:43:01.075.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
􀟈  Test run started.
􀄵  Testing Library Version: 2084
􀄵  Target Platform: arm64e-apple-macos14.0
􀟈  Test incompleteInverseMemberPlanIsRefusedBeforeHostDelivery() started.
􀟈  Test failedAcceptanceRecordReconcilesWithoutRedelivery() started.
􀟈  Test acceptedInverseFinalizesAfterReopenWithoutSecondHostDelivery() started.
􀟈  Test unknownOutcomeSuspendsOnlyItsScopeAndLaterReceiptRecovers() started.
􀟈  Test groupMustHaveWholeAuthoritativeMemberEvidence() started.
􀟈  Test failedRejectionRecordCannotCreateAnActionOnReopen() started.
􀟈  Test rejectedOrdinaryCommandHasNoActionAndNoEffect() started.
􀟈  Test unresolvedScopeDoesNotStopIndependentAcceptedRecovery() started.
􀟈  Test rejectedInverseOutcomeSaveFailureKeepsRedoFenced() started.
􀟈  Test actualSIGKILLRecoveryAtTransactionBoundaries() started.
􀟈  Test newOrdinaryCommandAfterUndoAbandonsRedoEligibility() started.
􀟈  Test wholeGroupInverseAndRejectionAreAtomicToCaller() started.
􀟈  Test failedBoundarySavesNeverMistakeMissingReceiptForRejection() started.
􀟈  Test acceptedCommandSurvivesReopenWithoutDuplicateDelivery() started.
􀟈  Test preparationAndCancellationNeverChangeHost() started.
􀟈  Test failedHistoryFinalizationPreservesAcceptedEffectAcrossRepeatedReopens() started.
􀟈  Test acceptedInverseAndRejectedInverseKeepEligibilityHonest() started.
􀟈  Test undoCannotSkipNewerAcceptedGroup() started.
􀟈  Test hostAcceptedBeforeHistorySaveIsNeverAppliedTwice() started.
􀟈  Test redoRequiresIdentityOfLatestCompensatingAction() started.
􁁛  Test incompleteInverseMemberPlanIsRefusedBeforeHostDelivery() passed after 0.015 seconds.
􁁛  Test acceptedInverseFinalizesAfterReopenWithoutSecondHostDelivery() passed after 0.029 seconds.
􁁛  Test groupMustHaveWholeAuthoritativeMemberEvidence() passed after 0.037 seconds.
􁁛  Test failedAcceptanceRecordReconcilesWithoutRedelivery() passed after 0.048 seconds.
􁁛  Test failedRejectionRecordCannotCreateAnActionOnReopen() passed after 0.056 seconds.
􁁛  Test unknownOutcomeSuspendsOnlyItsScopeAndLaterReceiptRecovers() passed after 0.068 seconds.
􁁛  Test newOrdinaryCommandAfterUndoAbandonsRedoEligibility() passed after 0.076 seconds.
􁁛  Test rejectedOrdinaryCommandHasNoActionAndNoEffect() passed after 0.082 seconds.
􁁛  Test acceptedCommandSurvivesReopenWithoutDuplicateDelivery() passed after 0.091 seconds.
􁁛  Test unresolvedScopeDoesNotStopIndependentAcceptedRecovery() passed after 0.101 seconds.
􁁛  Test wholeGroupInverseAndRejectionAreAtomicToCaller() passed after 0.115 seconds.
SIGKILL afterPrepare: signal=9, hostValue=7, actions=1
SIGKILL afterDelivery: signal=9, hostValue=7, actions=1
SIGKILL afterHostAcceptance: signal=9, hostValue=7, actions=1
SIGKILL afterAcceptanceRecord: signal=9, hostValue=7, actions=1
SIGKILL afterFinalization: signal=9, hostValue=7, actions=1
􁁛  Test actualSIGKILLRecoveryAtTransactionBoundaries() passed after 0.221 seconds.
􁁛  Test undoCannotSkipNewerAcceptedGroup() passed after 0.229 seconds.
􁁛  Test preparationAndCancellationNeverChangeHost() passed after 0.234 seconds.
􁁛  Test rejectedInverseOutcomeSaveFailureKeepsRedoFenced() passed after 0.244 seconds.
􁁛  Test acceptedInverseAndRejectedInverseKeepEligibilityHonest() passed after 0.255 seconds.
􁁛  Test failedHistoryFinalizationPreservesAcceptedEffectAcrossRepeatedReopens() passed after 0.264 seconds.
􁁛  Test failedBoundarySavesNeverMistakeMissingReceiptForRejection() passed after 0.268 seconds.
􁁛  Test hostAcceptedBeforeHistorySaveIsNeverAppliedTwice() passed after 0.276 seconds.
􁁛  Test redoRequiresIdentityOfLatestCompensatingAction() passed after 0.290 seconds.
􁁛  Test run with 20 tests in 0 suites passed after 0.291 seconds.
Runner report: /Users/ctwelve/.codex/worktrees/undokit-interface-proof/Folio/UndoKit/prototypes/recovery/.build/recovery-last-run.json
Memory and disk peaks are sampled watchdog observations, not calibrated benchmarks.
```

## Runner report

```json
{
  "source": "/Users/ctwelve/.codex/worktrees/undokit-interface-proof/Folio/UndoKit/prototypes/recovery",
  "source_head": "4cf43e50c1b3c62045959cb156180f81e78f54ea",
  "source_sha256": {
    "Package.swift": "4226604124840019d28c6f487af74f78e86b25e351b00ff37dc01ec141402b7f",
    "Sources/RecoveryChild/main.swift": "fcf48dd48a93cbf3437242e948dc495234c0d10ee567b54c652c2f120910ede7",
    "Sources/RecoveryProbe/RecoveryProbe.swift": "fb0f64f0923e019bc087c429a7624e01f07e1437911e6654de4e9d17809281d4",
    "Tests/RecoveryProbeTests/RecoveryProbeTests.swift": "a6cef68561b08bf28ba559e46a73f9f475b8df61ecdd1489f9f8926acb279575",
    "run.rb": "4dea3969d4a0d690d11ec30965ef2ac8949ccec9fd082b2cdb44d3d88f48afc9"
  },
  "fixture_directory": "/var/folders/l6/1jrtzdgs4xz0bb5pdz8mgknh0000gn/T/folio-recovery-20260929-20891-bpla2a",
  "limits": {
    "timeout_seconds": 180,
    "memory_bytes": 2147483648,
    "disk_bytes": 12884901888,
    "free_floor_bytes": 21474836480
  },
  "peak_sampled_memory_bytes": 157253632,
  "peak_sampled_owned_bytes": 86155264,
  "elapsed_seconds": 1.7838919999994687,
  "reason": null,
  "child_exit_status": 0,
  "child_signal": null
}
```

## Deliberately lowered watchdog limit

A separate runner check of the same tested source used
`RECOVERY_PROBE_MEMORY_MIB=1` and returned 124, as asserted by the invoking
shell. It verifies controlled refusal, not normal resource consumption.

```text
Recovery probe limits: {"timeout_seconds":180,"memory_bytes":1048576,"disk_bytes":12884901888,"free_floor_bytes":21474836480}
FAIL: combined descendant RSS limit exceeded; fixtures retained at /var/folders/l6/1jrtzdgs4xz0bb5pdz8mgknh0000gn/T/folio-recovery-20260929-21295-1lfgd5k

Runner report: /Users/ctwelve/.codex/worktrees/undokit-interface-proof/Folio/UndoKit/prototypes/recovery/.build/recovery-last-run.json
Memory and disk peaks are sampled watchdog observations, not calibrated benchmarks.
```
