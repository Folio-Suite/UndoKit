<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Recovery probe evidence

## Initial integration run, 2026-09-29

- Baseline: `52c498fcf7dc50b5c060820f217c957db74355f7`.
- Host: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Apple Swift 6.4.
- Command: `ruby UndoKit/prototypes/recovery/run.rb`.
- Compilation: Swift 6, complete concurrency checking, warnings as errors.
- Result: 17 Swift Testing tests passed, including five SIGKILL boundary modes.
- Integration test phase: 0.290 seconds. This small correctness run is not a scale
  benchmark and establishes no latency percentile or production safety ceiling.
- No resource override was used.

The five child modes terminate themselves with SIGKILL after preparation,
delivery-start recording, host acceptance, acceptance recording and finalization.
The parent checks signal termination, opens fresh store connections and observes
host values, history Actions and availability. The delivery-start/no-receipt case
remains Unresolved until a deliberately delayed host completion supplies evidence.
That completion is a fixture action, not a blind framework retry.

## Red/green evidence

The implementation worker first observed the accepted-command/reopen test fail
before implementation, then pass with separate stores. A later ordering test,
`undoCannotSkipNewerAcceptedGroup`, exposed an actual behavioral defect: an older
group was accepted for Undo, leaving host value 2 instead of the expected 3.
Persisted group ordering checks made that test pass. This records observed
implementation evidence; it does not claim every added test had an independent
failing implementation revision retained in Git.

## Scope and limitations

History uses a disposable programmatic Core Data model with normalized records
and string-key joins. Host state and its receipt are atomically replaced together
in a separate JSON file. This tests process interruption, not power loss or full
Core Data host integration. Managed objects remain private to the probe, whose
single writer is main-actor isolated; no production queue/concurrency claim follows.

Fault injection rolls back at specified history save boundaries; it is distinct
from inducing an actual filesystem or Core Data save error. Actual process kills
exercise the separate-store windows. Domain effects are synthetic integer changes;
malformed member evidence demonstrates suspension, not a real domain repair.

The tests do not establish generation reset, resource retention, pruning, native
AppKit behavior, copying/migration/corruption recovery or scale. Those require the
remaining accepted scenarios and proof tickets. A fixture target of macOS 14 is
not runtime evidence on that OS or Intel. No production UndoKit API was changed.

Maintainer acceptance is pending. #47 remains open.
