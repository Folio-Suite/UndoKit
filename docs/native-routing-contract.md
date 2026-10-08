<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Native Undo routing and restored availability

Accepted by the maintainer on 2026-09-29 through
[Folio issue #44](https://github.com/Folio-Suite/Folio/issues/44).
This contract extends [durable acceptance](durable-acceptance-contract.md),
[history retention](history-retention-contract.md) and the
[typed host interface](typed-interface-contract.md).
It specifies required behavior. The native bridge and durable history engine
remain unimplemented; interface compilation does not establish native behavior.

## Framework guarantees and host obligations

UndoKit supplies a reusable native bridge separate from its storage engine.
The host supplies a thin adapter with explicit application policy.

| Responsibility | Owner |
| --- | --- |
| Dispatch semantic Undo/Redo through ordered history operations | UndoKit bridge |
| Publish coherent availability and project finalized history into native presentation | UndoKit and bridge |
| Common action-name presentation and rebuilding on attachment | Bridge, using host-resolved names |
| Choose History Scope and distinguish local text from document history | Host |
| Settle native editing groups and submit their Commands | Host |
| Apply editing barriers and explain pending, rejected or suspended operations | Host, responding to framework signals |
| Interpret payloads, validate and compensate atomically, preserve authoritative outcomes | Host under the durable-acceptance contract |
| Refresh affected views and choose navigation/reveal behavior | Host |

UndoKit does not interpret affected-content metadata or manipulate application
views. Host obligations are part of the public integration contract and must
appear in eventual normative DocC, with examples and failure handling.

## Invocation, ordering and the editing barrier

Only one native semantic Undo/Redo invocation may be pending per History Scope.
Disable further native semantic Undo/Redo while it waits, executes and finalizes.
Restore availability from the finalized result. Unresolved recovery keeps the
scope unavailable. This restriction governs native invocation; the general
ordered submission queue remains available under its existing contract.

Before submission, the host settles the current native editing group according
to the control's editing rules and submits the resulting Command. Preserve
native typing coalescing and marked-text composition rules. Queue Undo after
prior edits and resolve its target when it reaches the head of the queue;
a menu's earlier availability snapshot cannot select a stale target.

From the waiting phase onward, the host temporarily prevents new native semantic
edits in every relevant view of that scope. UndoKit signals the pending state;
the host implements the barrier and feedback. Selection, scrolling and navigation
remain usable, and unrelated documents remain independent. Previously queued
and programmatic submissions retain the agreed ordering and validation rules.
A prior transaction that leaves the scope unresolved prevents the reversal
from proceeding until recovery permits it.

For example, typing followed immediately by Undo first settles and submits the
typing group. The reversal waits behind it with the editing barrier active,
then selects the eligible group from the resulting committed history. Repeated
Undo keypresses during that interval cannot enqueue additional native reversals.

## Group ordering, names and rejection

Use the group order, atomicity and Undo/Redo Position from the accepted history
contracts. A new accepted edit after Undo abandons ordinary Redo while retaining
the displaced branch according to retention policy. The bridge must not recreate
abandoned ordinary Redo from stale native registrations. Restoring retained state
uses the separately defined new undoable restoration transaction.

The host resolves action names from lightweight group metadata in the current
locale. Names are separate from stable operation identities. Missing or unusable
metadata falls back to localized ordinary Undo/Redo labels. Refreshing a label
must not require full state decoding or a history transaction.

One invocation attempts one group. If compensation is authoritatively rejected
without effects, finalize invalidation according to the host's dependency rules,
report rejection and refresh availability. Do not silently attempt an earlier
group on the same keypress. An earlier group proven independent by the host may
be offered for a new invocation. A partial group is prohibited; ambiguous outcomes
or incomplete finalization retain the suspension and recovery rules of #41.

## Focus, connected views and consumer policy

The host explicitly designates controls that have independent local text history.
A focused local editor with no local Undo must not fall through to unrelated
application history. Search fields or unsubmitted local drafts may use that
policy. Accepted Folio Manuscript edits belong to shared document ordering.

All attached views refresh accepted changes. Only the initiating view may reveal
affected content, and completion must respect deliberate navigation made while
the operation was pending. Keep origin context associated with the request;
completion must not steal focus, pull the user back, or transfer to a newly
selected document. The host interprets opaque affected-content information.

Folio uses document-wide order and may reveal affected content in the initiating
view. KitchenMemory uses its logical scene scope, native-text priority and no
automatic navigation. The bridge supports those policies without imposing one
consumer's semantics on the other.

For example, if Undo begins in document A and the user switches to document B,
completion updates A's attached views. It neither reverses B nor redirects focus
from B. If another view of A remains visible, its content refreshes without
acquiring the initiating view's navigation privilege.

## Coherent availability and attachment

Publish an immutable, versioned availability snapshot per History Scope containing:

- Scope identity and History Generation.
- Relevant Undo and Redo group identities and availability.
- Pending and suspended state.

The bridge discards stale updates and presents each snapshot coherently; hosts
resolve its names and application feedback. Bind a native manager to one scope
at a time. Attachment and reopening rebuild presentation from committed history
and enable commands only when ready. Rebuilding must not replay domain edits,
change content, dirty the document or claim successful acceptance prematurely.
Both Undo and Redo must be recoverable when the committed position permits them.

Detachment disconnects native presentation. It does not cancel a transaction
that has crossed the host boundary or redirect its completion to another
document. The host must continue the accepted outcome/recovery obligations even
when the initiating view disappears. The subsequently accepted
[store-lifecycle contract](store-lifecycle-contract.md) defines asynchronous
closing, recoverable unresolved work and session-bound Recovery Plans.

## Interference and asynchronous native mechanics

Every native registration must be associated with an accepted group or a
recognized provisional path. An unexplained registration pauses that bridge's
application-history commands and reports a mismatch. The host reconciles it
before resuming. Do not silently mix independent orderings or blindly clear
registrations that may represent user work. A bridge mismatch alone does not
establish store corruption, an Unresolved host outcome or suspension of unrelated
scopes.

The concrete native mechanism remains subject to proof: an UndoManager subclass,
command-routing adapter or other implementation has not been selected. Native
synchronous callbacks cannot claim completed asynchronous acceptance merely by
starting a task. Native stack changes, notifications, action names and document
change counts must reflect the agreed completion boundary. The proof must observe
these effects, including rejection and interrupted finalization.

## Required documentation and native proof

Public documentation must distinguish framework guarantees, host obligations and
consumer examples. It must explain scope attachment, editing-group settlement,
local text designation, pending barriers, ordering, action naming, authoritative
rejection, recovery, mismatch reconciliation, view refresh, origin tracking,
navigation, detachment and reopening. Include worked multi-window, focus-change,
rejection and interruption flows. Document the eventual bridge mechanism's native
notification and document change-count behavior after it has been proven.

The accepted [measurement plan](acceptance-measurement-plan.md) supplies the
scenario matrix and advisory timing targets. [#48](https://github.com/Folio-Suite/Folio/issues/48)
uses a disposable macOS AppKit host with real menus, keyboard commands, text
controls and document windows. Required observations include:

1. Two independent documents and multiple views of one document.
2. Native typing/group boundaries and a separate local text field, including
   an empty local history that does not fall through.
3. Delayed acceptance, authoritative rejection and unresolved outcomes;
   document change counts and notifications must match finalized outcomes.
4. Editing barriers, repeated Undo input and focus/navigation changes while pending.
5. Detachment and reopening with both Undo and Redo available, including relaunch.
6. Rebuilt presentation without content changes, dirtying or domain replay.
7. Detection and explicit reconciliation of unexplained native registrations.
8. Folio ordering/reveal policy and bounded KitchenMemory text-priority and
   no-automatic-navigation behavior.

Record actual native observations and human review separately from method-call
or compiler evidence. Failures return to the routing design before production
implementation. This selects a bounded proof, without asserting broad platform
certification or requiring a generic shared history UI. The #43 adapter/codec
proof does not satisfy these observations; #51 remains the design-and-proof gate.
