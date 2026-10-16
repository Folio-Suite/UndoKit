# First Undo Group, reopen and recover

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Register an operation once, submit typed values and attach native presentations.

## Establish ownership

Give a document a stable History Scope and working identity. Own a
``HistorySessions`` collection at application lifetime. Supply a
``HistorySessionConfiguration`` with history placement and a ``HistoryHostLease``
that acquires only domain resources. UndoKit retains ownership before acquisition
begins and closes its history resources before releasing the lease.

Register a ``HistoryOperation`` with the actual handler, current Command/effect
codecs and canonical fingerprint construction. Ordinary setup requires no state
codec or whole-document snapshot. Call `session.commands(for: operation)` once
and pass that typed handle to editing code.

## Submit values

```swift
@MainActor
func rename(_ command: Rename, using edits: HistoryCommands<Rename>) async
    -> HistorySubmissionResult {
    await edits.submit(command)
}
```

Here `Rename` is the application's transferable semantic Command. For several
members that must succeed atomically, use `submitGroup`. The host receives the
whole ordered group and commits effects plus authoritative receipts atomically.
Separate callbacks cannot establish an atomic mixed-family group.

An accepted result includes the finalized history receipt. An unexecuted result
proves that this request did not reach delivery. An unresolved result preserves
its original identity for recovery; do not invent another identity and retry the
effect. Waiting followers stop explicitly and do not resume after reconciliation.

## Attach native editing

Call `session.attach(owner:statusDidChange:)` for each window. Return the
attachment's `undoManager` from the normal document/window/responder provider.
A ``HistoryField`` supplies stable field/mapping identities, its value codec,
an authoritative value plus revision, and a mapping to the typed handle.
UndoKit handles capture, journaling, settlement and refresh across presentations.

Live native Undo/Redo before settlement does not create durable deliveries.
An editing boundary settles one transaction. Subsequent durable Undo/Redo creates
new accepted records. Marked composition may finish while the admission barrier
blocks new editing. A local scratch editor keeps its own history and never falls
through to an unrelated document group.

Detaching a window releases presentation callbacks, not the shared session's
writer or recovery evidence. Explicitly close the session at the domain ownership
boundary. Unknown native registrations remain preserved and block integration
until the host explicitly reconciles them.

## Reopen

Use `.existing` for registered history. Opening consults authoritative host
receipts before allowing new delivery. Recovered field drafts require an explicit
retry/discard decision. Exact prepared intent survives uncertainty; equal field
values do not establish equal authoritative revisions.

The Durable Notes examples exercise AppKit, UIKit and SwiftUI against the same
domain host. The independent consumer verifies a two-member group, Undo, Redo and
reopen: three accepted deliveries, six applied members and three host receipts.
See the repository's getting-started guide for the runners and evidence limits.

## Topics

- ``HistorySessions``
- ``HistoryOperation``
- ``HistoryCommands``
- ``HistoryAttachment``
- <doc:RecoveryAndStorage>
