# ``UndoKit``

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Durable application history through typed Commands and the app's native UndoManager.

## Start with one shared session

An application owns a ``HistorySessions`` collection. Each stable History Scope
has one ``HistorySession``, shared by its windows and views. UndoKit opens and
closes history storage, orders submissions, safeguards field drafts and coordinates
recovery. A host lease owns only the application's domain resources.

Declare a ``HistoryOperation`` once with its stable family, Command and effect
codecs, canonical Intent Fingerprint and actual host handler. Obtain a typed
``HistoryCommands`` handle from the session. Editing code submits values without
building encoded payloads, assigning retry identities or supplying checkpoint
snapshots. Use an atomic group when several members must succeed together.

Attach a presentation with ``HistoryAttachment`` and supply its `undoManager`
through the app's document, window or responder. Native field bindings map a
value and its authoritative revision to the same typed Commands. AppKit and
UIKit retain their native live typing behavior; UndoKit settles complete editing
transactions into durable Undo Groups.

- <doc:InstallingUndoKit>
- <doc:FirstUndoGroup>
- <doc:RecoveryAndStorage>
- <doc:RetainedHistoryAndResources>
- <doc:PreviewCompatibilityAndSupport>

## Keep meaning in the host

The host owns semantic validation, canonical intent, atomic domain effects and
outcome receipts, resource preservation and policy. UndoKit owns the ordering and
durable evidence of these opaque operations. An Accepted Outcome must agree with
the host's persisted state. A possible effect with no authoritative outcome is
unresolved, never a rejection.

Handlers may belong to MainActor or a separate actor. Codecs execute on their
registered handler's actor. Transferable Command values must represent stable
intent; declarations can capture immutable values from mutable references before
submission suspends. Actor-local advanced adaptation keeps non-Sendable domain
values on their owner.

Do not await another request to the same scope inside a host callback. Such
reentry is refused before it can wait behind itself.

## Await the result and observe readiness

``HistorySubmissionResult`` distinguishes acceptance, rejection, unexecuted
requests, proved usable delivery failures and unresolved work. Acceptance means
both the host's effect and history finalization completed. It is separate from
presentation readiness: an authoritative refresh may fail after acceptance.
Observe ``HistorySessionStatus`` before allowing native editing.

The bounded FIFO reserves a position before asynchronous encoding. Cancellation
removes waiting requests. Once delivery may have begun, recovery preserves the
exact prepared identity. Uncertainty completes queued followers as unexecuted;
reconciliation never automatically replays them. Submit new intent explicitly
after recovery and host validation.

A presentation can detach without closing its shared session. Explicit session
closure safeguards drafts, stops waiting work and waits for active recovery or
delivery before releasing history resources and then the host lease. Failed
closure retains the responsible owner in the application collection.

## Advanced integration

Applications that need opaque payloads and direct resource ownership can use
``HistoryStore`` and ``HistoryEngine``. These form a lower-level integration path.
Do not open a competing owner underneath an ordinary session. Focused session
capabilities reach that session's existing owner and its admission fences.

| Capability | Responsibility |
| --- | --- |
| ``HistoryTransactions`` | Opaque Commands, complete-group Undo/Redo and outcome reconciliation |
| ``HistoryReading`` | Metadata, checkpoints and protected reconstruction reads |
| ``HistoryRetentionManaging`` | Checkpoints, Retention Holds and bounded consolidation |
| ``HistoryStore`` | Physical registration, independent scopes, read-only inspection and coordinated copies |
| ``HistoryEngine`` | Direct scope ownership, recording policy and generation changes |

Reading retained history does not move the live Undo position. A restoration is
new host-validated intent with restoration provenance. Recovery Plans and
Retention Holds protect the material needed for reconstruction; they do not
implicitly restore domain state. Keep object cleanup behind retention fences.

## Source navigation

`Interface/Application/` contains ordinary sessions, handles, attachments and
platform bindings. `Interface/Hosting/` contains shared handler and codec setup.
`Interface/Advanced/` contains transactions, retained history and storage access.
Shared identities, results and policy values remain at `Interface/`.

Implementation lives in `Modules/`: Transactions owns admission and durable
lifecycle, HostAdaptation owns typed dispatch, NativeEditing owns field settlement
and native routing, RetainedHistory owns reconstruction and retention, and Storage
owns persistence and physical writer protection. There is one dynamic product
and runtime identity.

## Support and persistence

Use `.create` only for new history and `.existing` for known history. Missing,
corrupt or unsupported bytes are preserved and refused. Opening never silently
replaces original history. An independent working copy needs a distinct working
identity and coordinated domain data.

This pre-release refactor has no compatibility wrappers or old draft-format
migration. Current-format recovery and original-data preservation remain required.
Consult the matching release evidence for platform qualification; source builds
and simulator checks alone do not establish physical-device or floor-OS support.

## Topics

### Application integration

- ``HistorySessions``
- ``HistorySession``
- ``HistoryCommands``
- ``HistoryAttachment``
- ``HistoryField``
- ``HistorySessionStatus``
- ``HistorySubmissionResult``

### Host setup

- ``HistoryHostLease``
- ``HistoryOperation``
- ``HistoryOperationHandler``
- ``MainActorHistoryOperationHandler``
- ``HistoryCodec``

### Advanced capabilities

- ``HistoryTransactions``
- ``HistoryReading``
- ``HistoryRetentionManaging``
- ``HistoryStore``
- ``HistoryEngine``
- ``HistoryFailure``
