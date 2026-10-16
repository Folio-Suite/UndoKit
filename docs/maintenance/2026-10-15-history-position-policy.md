<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Undo/Redo Position policy — 2026-10-15

`HistoryPositionPolicy` is the internal owner of ordinary Undo/Redo Position
across retained History and recording-off session effects. It selects the
highest-sequence eligible Undo Group and the lowest-sequence eligible Redo
Group from the shared retained/transient candidates, and applies one invalidation
barrier across both representations. Availability and actual inverse delivery
use the same selection path.

Accepted retained transitions update retained group state and Redo branching in
the history save that records the accepted transaction. Accepted recording-off
transitions update transient effect positions after their receipt is saved.
Rejected inverse transitions invalidate retained eligibility in the rejection
save and transient eligibility only after that save succeeds. Recording
boundaries update the persisted floor/mode with their baseline or checkpoint
write, then retire session-only inverse effects after the write commits.
Generation resets also retire session-only effects. Durable action payloads,
host receipts, transient effects, resource references and recording policy keep
their existing storage and lifetime rules.

The public characterization test verifies retained-to-Off ordering, availability
at each position, distinct receipts, exact host-delivery order, and Redo order.
Existing recording, invalidation, generation, recovery and persistence-failure
tests continue to exercise rejection barriers, resource protection, receipt
reconciliation and reopen behavior.

Validation on the current candidate:

- `scripts/test-package.sh --filter 'HistoryRecordingTests|HistoryInverseInvalidationTests|HistoryGeneration|HistoryRecoveryIntegrityTests|HistoryPersistenceFailureTests'` — Debug, 25 tests passed.
- `scripts/test-package.sh -c release --filter 'HistoryRecordingTests|HistoryInverseInvalidationTests|HistoryGeneration|HistoryRecoveryIntegrityTests|HistoryPersistenceFailureTests'` — Release, 18 tests passed.

The builds reported existing generated Core Data unused-import warnings and a
captured-mutation warning in `HistoryPrerequisiteCancellationTests.swift`.
