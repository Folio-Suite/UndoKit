# Recovery, storage and concurrency

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Preserve exact intent and authoritative evidence across uncertainty.

## Show the next action

Keep session status visible to the person editing the document. A disabled
editor without an explanation is difficult to distinguish from a broken app.

| What you observe | Next step |
| --- | --- |
| Busy delivery | Keep the owner; wait for the authoritative result. |
| `requiresDraftDecision` | Offer `retryDraft()` and `discardDraft()` with an explanation of the retained draft. |
| Suspended transaction | Await `session.reconcile()`; it consults the original host receipt. |
| Storage unavailable | Restore access to the original document, then finish closure before reopening it. |
| Close did not reach `.closed` | Keep the session/domain lease and report the blocking issue. |

Use the session or binding's supported methods, rather than clearing native
registrations, resetting a generation or opening another history store. A retry
of a retained draft and a new Command are different operations.

## Acceptance is host-authoritative

The host's domain state and outcome receipt must agree atomically. If a delivery
may have changed state, report unresolved until authoritative lookup establishes
acceptance or rejection. UndoKit preserves prepared intent and suspends unsafe
inverses while it reconciles. Never invent a fresh identity, clear unknown native
registrations, or fall through to an older group to escape this uncertainty.

The durable samples include a Debug-only control that accepts an effect before
history finalization fails. Graceful close/reopen then recovers the original
Accepted Outcome using its authoritative receipt without duplicating the effect.
This is injected production-boundary recovery evidence, not abrupt-termination
certification. Release builds omit the Debug injection control.

A reopened retained draft is decision-gated. The host explicitly retries or
discards the preserved draft; ordinary editing does not silently accept it.
App-owned session collections retain blocked complete leases after presentation
is released. Close the blocked session before reopening storage that has returned.

## Preserve original storage

Missing known history, corrupt bytes, an incompatible model or an identity
conflict must be refused and preserved. Do not silently replace them with empty
history or reset a generation. ``HistoryStore`` opening validates supported model
and identity before writable access; the host still coordinates external writers,
moves, document resources and copies.

A coordinated copy pairs closed history with coherent host data and dependencies.
Unresolved work blocks an ordinary independent copy. Storage capacity checks can
refuse before copying. History is not the primary datastore or a backup for
missing host resources. Keep a recoverable coherent original for any supported
upgrade; there is no downgrade guarantee.

## Respect actor and lifecycle ownership

Session/capability calls and native presentation are MainActor isolated. A host
handler may own another actor; immutable encoded values cross that boundary.
Applications establish intended submission order before admission. Each scope
serializes delivery, but do not await another submission to the same scope from
inside its host callback.

Cancellation after delivery cannot retract its semantic effect. Presentation
teardown disconnects recognized callback graphs while the app retains recovery
ownership as needed. Call explicit close and await delivered work reaching a
recoverable boundary before releasing the domain lease. A disappearing window
is not a guarantee that persistence succeeded.

## Topics

- ``HistoryFailure``
- ``HistoryStore``
- ``HistoryEngine``
- ``HistoryHost``
- <doc:RetainedHistoryAndResources>
- <doc:PreviewCompatibilityAndSupport>
