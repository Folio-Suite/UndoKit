<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# First Undo Group, reopen and recover

Begin with [installation](installation.md) and the runnable
[Durable Notes hosts](../Examples/DurableNotes/README.md). The example's note and
receipt state is independent of UndoKit's history database. The same domain core
is used by AppKit, UIKit and SwiftUI shells; no Folio/KitchenMemory model is needed.

## Establish ownership before editing

Give each document a stable History Scope and working identity. A window is a
presentation of that document, not its scope identity. The app owns its document
session collection and complete domain lease; transient views own neither the
writer nor blocked recovery. Use `.create` only for new history and `.existing`
for known history. Missing, corrupt or incompatible existing files are not an
invitation to create replacement history.

Create a `HistoryOperation` once, binding its actual handler, current Command and
effect codecs, and canonical intent construction. Open a `HistorySession` through
`HistorySessions`, then obtain `session.commands(for: operation)`. Host leases
acquire domain resources only; the framework owns history storage. Ordinary
submission needs no checkpoint codec or whole-document state.

Several windows attach to the same working History Scope. Return each attachment's
UndoManager from the app's normal document/window/responder provider. For complex
integrations, focused `session.advanced` capabilities use the same owner. A standalone
`HistoryStore`/`HistoryEngine` integration remains available for opaque transactions
and explicit ownership. It must not compete with an existing session.

## Submit one group

The independent compiled example is
[`scripts/consumer/HostFixture.swift`](../scripts/consumer/HostFixture.swift).
Its literal two-member Command sets `alpha`, then `alpha-beta`. One host delivery
atomically writes the complete resulting state and token-bound effects/receipt.
The engine finalizes one Undo Group after authoritative acceptance. Undo restores
the empty baseline; Redo restores `alpha-beta`. After all three accepted deliveries,
the host has three receipts and six applied members. Reopen verifies this host
state independently of Undo availability.

A host filters known no-ops and defines canonical intent once in its operation
declaration. The framework assigns and retains the prepared Command identity. A Command is a request; an Accepted Outcome
establishes its effect. The host applies every group member atomically or proves
that none took effect. A failure after a possible effect is unresolved, not a
rejection. Reuse the exact Command/token identity when reconciling uncertainty.

Await finalized `HistorySubmissionResult`, rather than treating enqueueing or a native Undo
registration as a durable receipt. `.accepted` follows both the host's effect and
history finalization. `.rejected` establishes no effect. Unexecuted requests are distinguished from unresolved delivered work. Queued
followers stop on uncertainty and never replay automatically after reconciliation.
Observe session status as well: a refresh can fail after acceptance.

## Keep live typing native

Attach field declarations with stable identities, authoritative value/revision
reads and typed Command mappings. Use the supported [AppKit binding](appkit-history-binding.md) or
[UIKit binding](uikit-history-binding.md). Native text controls retain their real
live Undo/Redo microhistory. Explicit editing transactions become persistent
Undo Groups; native registrations are not serialized as durable history.

Typing `Alpha`, native Undo to baseline, then native Redo should cause no durable
delivery. Commit typing creates one intended group. Subsequent durable Undo and
Redo each create one authoritative host receipt. A local scratch control keeps
priority and must never fall through to an older document group when empty.
Keep marked composition intact; settlement waits for a supported boundary.

SwiftUI presents framework-owned native-backed editors. Keep editor, binding and
session in a stable scene/document owner and use `nativeHistory(binding)` for the
explicit `nativeHistoryUndoManager` environment. The SDK's built-in undoManager
is read-only. Remounting a SwiftUI value does not create another writer or replace
the native manager. See the runnable
[iPhone/iPad](../Examples/DurableNotes/SwiftUI/README.md) and
[Mac](../Examples/DurableNotes/SwiftUIApp/README.md) guides.

## Reopen and reconcile an uncertain result

The native samples offer deterministic Debug failure controls that let the host
accept an effect before history finalization fails. Use the host's documented
control, inspect the preserved draft and receipt, gracefully close and reopen,
then explicitly retry/reconcile the preserved draft. Acceptance must be recovered
from the original authoritative receipt exactly once. Do not submit a fresh
identity, clear unknown registrations, or issue an older inverse through the
blocked operation. Release-only runs exclude injected Debug controls.

Reopening a retained draft requires an explicit retry/discard decision. A blocked
presentation may disappear while the app-owned session keeps the original lease
and evidence. Close the blocked session before reacquiring its writer after
storage returns. A known missing original is refused, not silently recreated.

This is production-boundary injected failure plus graceful close/reopen evidence.
It does not certify abrupt process termination, physical file-protection locking,
hardware keyboards or real IME behavior. Follow the exact host runner's retained
source/configuration/runtime manifest and independent Note.json/receipt readback.

## Continue beyond ordinary Undo

- [Retained history and reconstruction](history-reconstruction.md): reading does
  not move live Undo position. Reconstruct with host codecs/resources, validate,
  then submit a new restoration Command.
- [Retention contract](history-retention-contract.md): Checkpoints and Retention
  Holds distinguish state protection from detailed-history protection. Run bounded
  maintenance; do not delete host resources still required by retained history.
- [Compatibility and storage](history-compatibility.md): unsupported formats are
  preserved/refused; this greenfield refactor provides no old-format reader or migration.
- [Native session lifetime](native-editing-session-contract.md): presentation
  cleanup does not cancel delivered work or discard unresolved recovery evidence.
