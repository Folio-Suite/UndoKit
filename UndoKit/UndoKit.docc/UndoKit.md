# ``UndoKit``

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Durable application history behind a native UndoManager interface.

## Ownership

UndoKit orders opaque commands, persists transaction evidence and accepted action
relationships, and projects finalized availability into native Undo. The host
owns semantic meaning, validation, no-op filtering, atomic compensation, durable
outcome receipts, resource preservation, and application policy. No Folio model
is required. Swift clients import `UndoKit`.

## Public interface map

- `Interface/HistoryStore.swift` — physical registration, placement, read-only inspection, copies, capacity and closure.
- `Interface/HistoryEngine.swift` — scope command submission, Undo, Redo and availability.
- `Interface/HistoryQueries.swift` — checkpoints, bounded history pages and scope closure.
- `Interface/HistoryRecovery.swift` — reconciliation of interrupted or suspended transactions.
- `Interface/HistoryTypes.swift` — host contract, payloads, results, failures, snapshots and limits.
- `Interface/HistoryCodecs.swift` — explicit payload codecs and host handler contracts.
- `Interface/HistoryRegistrations.swift` — typed operation registrations and host families.
- `Interface/HistoryActorRegistrations.swift` — actor-isolated typed submission and dispatch.
- `Interface/HistoryMainActorRegistrations.swift` — Cocoa main-actor typed submission and dispatch.
- `Interface/HistoryReconstruction.swift` — plan, step, material and read identity types.
- `Interface/HistoryRecoveryPlanning.swift` — bounded reads and temporary protection.
- `Interface/HistoryPresentation.swift` — opaque metadata and coherent native names.
- `Interface/NativeHistoryRouter.swift` — native UndoManager routing and editing barriers.
- `Resources/History.xcdatamodeld` — the framework-owned persistence schema.

Durable transaction and storage helpers are implemented in `Modules/History/`.
The native manager helper stays with the router because it implements the public
router's AppKit behavior.

## First supported operation

``HistoryStore`` registers a physical Core Data database. A writable session owns
its writer lock and may open several ``HistoryEngine`` scopes with separate hosts,
ordering, availability and recovery state. A read-only session can inspect
committed history and pending recovery evidence while the writer remains open.
The `HistoryEngine.open` convenience owns one store and scope.

An engine supports bounded command groups, durable Undo/Redo, explicit checkpoint
snapshots, restoration provenance, and retained displaced continuations. A new
edit after Undo retires ordinary Redo eligibility while retaining its records.
Undo and Redo create accepted records instead of deleting the original edit.

An opaque ``HistoryHost`` may be isolated to the main actor or another actor.
Typed hosts use ``HistoryOperationRegistration`` with stable operation, schema,
codec, configuration, and version identifiers. Register again from application
code after opening; runtime closures and actors are never stored in the history.
``HistoryCodec`` provides explicitly selected JSON, XML property-list, and
binary property-list conveniences, plus custom codecs. Codec identity and
configuration are embedded with encoded values, so same-version bytes cannot be
silently interpreted using changed settings. A custom codec owns the meaning of
its configuration bytes; built-in Foundation codecs use their documented
defaults. Supply a host-defined canonical intent fingerprint rather than
deriving it from an ordinary encoding.

``HistoryOperationHandler`` keeps non-Sendable values on its actor;
``MainActorHistoryOperationHandler`` supports Cocoa document models. Each
delivery contains the complete ordered group, and the handler must apply all
members atomically or prove that none took effect. A mixed-family group needs an
explicit atomic group executor in ``HistoryHostRegistry``. A callback failure
after possible effect is unresolved. Reentry into the same engine is rejected
before it can wait behind the active request.

``HistoryEngine/submit(_:)`` preserves queue admission order. Applications must
establish their intended submission order. Completion follows history
finalization. Storage failures after domain acceptance preserve that acceptance
and suspend availability until reconciliation succeeds. Inspect the cause,
stage, and disposition in ``HistoryFailure``; never retry by inventing a new
identity for a possibly delivered command.

Use `.create` only for a new store and `.existing` for a known store. An explicit
independent copy supplies the source working identity and a new identity.
Opening does not replace missing or unsupported history with an empty store.
``HistoryStore/withCoordinatedCopy(to:capture:)`` stops admission across all
scopes, waits for delivered work, and supplies a closed SQLite copy while the
host captures matching domain data and dependencies. Unresolved transactions
block an ordinary independent copy. Opening the copy with `.independentCopy`
changes its working identity while preserving inherited history. A move retains
the original identity. ``HistoryStore/close()`` stops all scope admission and
releases ownership after delivered work reaches a recoverable boundary. Closing
an individual engine leaves other scopes open. The host keeps
its own data store and does not use UndoKit as its document write-ahead log.

## Checkpoints and bounded reading

Checkpoint state is an opaque ``HistoryPayload`` supplied by the host. Secure
its dependencies first. The host owns document saving and confirms that saving
succeeded before announcing a saved checkpoint. Metadata pages do not decode
all retained state. Retrieve the selected checkpoint explicitly, reconstruct and
validate it in the host, then submit a new command with its identifier as
`restorationOrigin`. Browsing and checkpoint retrieval never move Undo position.

``HistoryLimits`` configures admission and ordinary Undo depth. Depth counts
complete original groups, sharing the allowance with Redo. It does not promise
that all retained history occupies only that many records. This slice preserves
history rather than implementing pruning. Payload integrity checks are separate
from the host's canonical intent fingerprint.

## Historical reconstruction

Call `beginRecoveryPlan(from:to:using:)` with the host's explicit `.acceptedEffects`
promise only when stored Undo/Redo evidence represents complete state transitions.
Capture coherent host state before choosing `.current`; a checkpoint source
supplies a stored baseline. A checkpoint target uses its own snapshot. Fetch bounded
`recoveryPage` references and one `recoveryMaterial` member at a time. Apply reverse
steps in reverse member order, or forward steps in forward member order, in an
isolated host reconstruction. These reads never deliver commands or move live Undo.

Release or cancel each plan when finished. A cancelled task's next read also
releases its plan. Closing the scope invalidates all handles. Missing targets,
stored gaps and unavailable member evidence produce failures. The plan's committed
version identifies its fixed historical view even if later commands arrive.

`HistoryCommand.presentation` carries at most 4 KiB of opaque host metadata.
`presentation(forGroup:)` retrieves it without reconstruction.
`nativeActionNames(resolve:)` returns host-decoded labels and the matching
availability snapshot in one actor turn. `readIdentity()` exposes scope,
generation and committed version for history presentation.

## Native hosting

``NativeHistoryRouter`` supplies an UndoManager to native controls. NSTextView
retains its native grouping and coalescing. The host settles provisional input
before a reversal, submits prior edits in order, applies the router's editing
barrier, and completes the asynchronous invocation with finalized availability.
Marked composition must finish before settlement. Independent local text controls
keep their own managers and must not fall through to unrelated document history.

Do not assign the provisional manager to NSDocument: its automatic group-close
change counting would run before host acceptance. The document host counts each
authoritative result once and separately reports provisional input as edited.
Rebuilding availability after opening neither invokes an old callback nor dirties
the document. An unexplained native registration pauses routing until the host
reconciles it. The bridge does not navigate or interpret affected-content data.

## Current limits

The first operation is not the complete accepted UndoKit design. Recording
controls, generation reset, retention holds, resource-reference maintenance and
pruning/consolidation need follow-up implementation. Host payloads remain bounded.
The independent tests do not
establish production behavior at the prototype's 100,000-group scale.

The storage format and Swift interface are pre-alpha. No old-store migration or
independent binary compatibility is promised. Objective-C and XCFramework
publication remain deferred. Apps and Kits ship as a coordinated Suite version.

## Topics

### Durable history

- ``HistoryEngine``
- ``HistoryStore``
- ``HistoryHost``
- ``HistoryCommand``
- ``HistoryPayload``
- ``HistoryResult``
- ``HistoryFailure``
- ``HistoryLimits``
- ``HistoryCodec``
- ``HistorySchemaIdentity``
- ``HistoryOperationRegistration``
- ``HistoryOperationHandler``
- ``MainActorHistoryOperationHandler``
- ``HistoryHostRegistry``

### Native integration

- ``NativeHistoryRouter``
- ``HistorySnapshot``
