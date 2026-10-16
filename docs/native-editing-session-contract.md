<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Shared History Session and native editing

The ordinary interface is `HistorySessions` → `HistorySession` → typed
`HistoryCommands` and presentation `HistoryAttachment`s. The accepted ownership
and failure rules are in [ADR 0007](adr/0007-shared-native-history-coordination.md)
and the [session design](session-interface-design.md).

## Ownership

One application-owned collection retains one session per working History Scope.
Multiple windows attach to that owner. A host lease owns domain resources; UndoKit
owns history stores, writer arbitration, admission, field journals and recovery.
The collection retains acquisition and failed-closure owners. Detaching a view
never transfers or releases domain/history ownership.

A field declaration binds stable field and mapping identities, its current codec,
an authoritative value and opaque revision, and the typed Commands that implement
a proposed change. Equal values are not interchangeable revisions. Captured intent
is bound to the original base and History Generation; settlement cannot silently
reread and rebase it.

There is one live native editing transaction per scope. Passive attachments receive
authoritative refreshes without overwriting the active draft. Focus transfer settles
the preceding transaction before another editor begins. Native live work is retired
only for the matching transaction, after its accepted result and successful refresh.

## Admission

Typed requests reserve their FIFO position before asynchronous encoding. Native
settlement participates in that same queue as a prerequisite, not through another
submission chain. A rejected or uncertain prerequisite stops the dependent request;
it cannot fall through to an older inverse. Independent proved rejections do not
invalidate later independent Commands.

Native editing and native Undo/Redo are blocked while durable work is waiting or
executing. Existing marked composition can finish. No adapter forcibly commits
marked text or strands it behind a barrier that only settlement can release.
Closure wakes composition waiters after preserving the field journal.

Cancellation removes unprepared waiting work. Uncertainty returns queued followers
as explicitly unexecuted with recovery required. They never resume automatically.
The active operation retains its exact prepared identity and authoritative evidence.
Acceptance and presentation readiness are separate: refresh failure can block the
session after a receipt has already been accepted.

## Native routing

Supply the attachment's UndoManager through the application's normal document,
window or responder provider. AppKit forwards only exact recognized editor and
text-storage registrations to a dedicated live manager. UIKit retains its native
original-manager route. Both use the same field transaction policy.

Local scratch controls remain isolated, including when their own stack is empty.
Unknown registrations retain their callback graphs and block integration. Acceptance,
detachment and recognized live-stack cleanup cannot clear them. Explicit native
reconciliation requires the host to identify the authored work and reconcile its
values first.

## Recovery and closure

Current-format journals include scope, working identity, generation, field/mapping
identity, codec/version, base value/revision, captured value and exact prepared
Command. Unsupported formats fail explicitly; this greenfield interface provides no
legacy whole-document draft reader or migration.

Reopened drafts require an explicit retry/discard decision. Retry consults the exact
prepared identity. Discard cannot erase possible host effects. Failed acquisition,
journal safeguarding or closure leaves an inspectable retained owner.

Close safeguards fields, stops new admission, completes waiting requests as
unexecuted, drains active work to its durable recovery boundary, closes framework
resources, then releases the domain lease. Closing during opening cannot restore
readiness when the delayed acquisition completes. A closed session's handles and
attachments cannot act on a replacement owner.

See [AppKit](appkit-history-binding.md), [UIKit](uikit-history-binding.md), and
[SwiftUI](swiftui-appkit-history-binding.md) for presentation mechanics. Runtime
checks qualify the tested candidate only; they do not establish physical IME,
floor-OS or Intel runtime behavior.
