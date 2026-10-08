<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Disposable native Undo proof (#48)

Run `ruby run.rb` here. It runs Swift 6 strict-concurrency tests with a 180-second
and 2 GiB child-process limit, then places `FolioNativeUndoProof.app` in the
system temporary directory. The app reads and writes only the scratch fixture
shown by the runner and each window's event log. Launch with the printed command.
The package contains no production UndoKit source and uses a tiny JSON snapshot
fixture to test routing and relaunch.

Runner overrides may tighten limits. The accepted ceilings are 600 seconds,
2 GiB child-process memory, 12 GiB owned temporary disk and a minimum 20 GiB
free-space floor; weaker settings are rejected. The runner counts its build,
app bundle and both scratch fixtures, and stops/reaps its child tree if a
watcher fails. A failed run preserves a timestamped JSON diagnostic beside
`last-run.json`. `NATIVE_PROOF_WATCHER_FAULT=ps`, `du` or `df` injects a watcher
failure for a small cleanup smoke. These limits cover build and tests, not the
interactive app session.

Two `NSDocument` instances, A and B, open as separate windows. The document text
view accepts real AppKit text input. Pause 0.55 seconds to settle one semantic
group, then use the Edit menu or Command-Z / Shift-Command-Z. The local draft
has a separate native `UndoManager`; an empty local Undo consumes the command.
`Clone A` opens another view of A. `Detach clone` closes it and `Reopen clone`
re-attaches it. The outcome popup chooses immediate, delayed, rejected or
unresolved completion; delayed completion waits 10 seconds. `Show A` / `Show B`
or Command-1 / Command-2 explicitly select the document windows.
`Inject unknown` pauses semantic routing until
`Reconcile` classifies the deliberately inert registration. `Resolve` declares
the unresolved fixture outcome to have had no effect. That resolution is a
simulated authoritative host answer for the fixture.

For a two-direction relaunch check, type two settled groups in A, Undo once,
quit, and reopen the app with the same `NATIVE_PROOF_DIR`. The A window should
show both Undo and Redo. Its event log should say rebuilt with no replay, and
`NSDocument edited` should be false before new input. The status also shows a
proof-owned accepted-change balance; AppKit does not expose its change count.

The bridge seam is `NativeProofCore`. It publishes scope, generation, version,
group identities, names, pending and suspended state. Automated tests check
rebuild, one pending invocation, rejection, unresolved state, interference and
Redo abandonment. The real AppKit session is required for menu, keyboard,
focus, typing and notification observations.

## Known proof limits

- The host settles typing with a 0.55-second idle boundary and calls
  `breakUndoCoalescing()` on the native editors. A marked composition blocks
  semantic Undo/Redo until it commits; the user must retry afterward. This
  prevents selection of a stale prior group, but composition was not exercised
  in the native session and exact AppKit typing-group correspondence is unproved.
- The editor's low-level native `UndoManager` registrations are provisional;
  semantic Undo is routed through the menu/responder action and never asks that
  manager to replay them. Native `NSUndoManager` notifications therefore do not
  yet reflect asynchronous semantic finalization. The event log observes real
  native typing-manager group-close, Undo and Redo notifications to make this
  distinction visible. This is a design gap for #51.
- `ProofHistory` truncates the ordinary Redo suffix after a new accepted edit.
  It is a routing projection, not evidence that displaced history is retained
  as a durable branch; #50 owns that proof.
- The `Inject unknown` control registers an inert native action and explicitly
  informs the bridge of the mismatch. It uses `NSDocument.undoManager`; AppKit
  marks the document edited when that action registers in the observed session.
  Reconciliation preserves that dirty signal. This proves the pause/reconcile routing
  response, but not automatic discovery of an unexplained third-party
  registration. The inert native action remains registered after reconciliation.
- The fixture's snapshot JSON file is deliberately separate from #47's Core
  Data durable-acceptance prototype. It demonstrates saved availability, not
  transaction crash recovery or production package storage.
- The proof reports `NSDocument.isDocumentEdited` and calls real
  `updateChangeCount` methods. The numeric balance shown beside it is a fixture
  counter, since AppKit does not expose the document's internal count.
