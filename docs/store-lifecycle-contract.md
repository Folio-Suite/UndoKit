<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Store lifecycle and safe capacity

Accepted by the maintainer on 2026-09-29 through
[Folio issue #45](https://github.com/Folio-Suite/Folio/issues/45), following
21 decisions and final agreement. This contract extends
[durable acceptance](durable-acceptance-contract.md),
[history retention](history-retention-contract.md),
[typed interfaces](typed-interface-contract.md) and
[native routing](native-routing-contract.md).
It records required behavior; the production history engine remains a scaffold.

## Placement, registration and ownership

The host chooses the history location. UndoKit owns its internal files, layout
and supported maintenance operations. A document- or library-centric host
registers which history database belongs to each file or bundle. Folio keeps
history within its native Document package so it travels with the Document.
UndoKit does not discover documents or infer their ownership from paths.

For applications whose history belongs to the application, UndoKit provides a
persistent default in Application Support, found through Foundation and scoped
to the application identity and a stable store name. KitchenMemory is the
bounded example. Reopening resolves the same store. Hosts without a usable
application identity supply a namespace or location; shared hosts explicitly
configure their shared location. A failed explicit location produces an error,
never a silent fallback to a different database.

Apple describes Application Support as the location for app-specific support
and user data, conventionally namespaced by bundle identifier. Foundation resolves
its location in the app's sandbox when applicable. See
[Apple's directory guidance](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html)
and [Foundation's Application Support location](https://developer.apple.com/documentation/foundation/url/applicationsupportdirectory).

One physical history store may contain multiple History Scopes. Ordering,
Undo/Redo Availability and retention policy belong to each scope. Physical
capacity and store-wide failures belong to the containing store. Folio ordinarily
uses one store per Document; KitchenMemory may use one app-local store for
several logical scopes.

Only one active UndoKit owner may write a physical store. Other clients submit
through that owner; a competing writable open reports an ownership failure.
The implementation must prove ownership release and recovery after interruption.
No particular locking mechanism is selected here.

## Identity, creation and opening

A working history-store instance has an identity distinct from its location,
History Scope, History Generation and copied historical record identities.
Moving or renaming preserves continuity. An independent working copy receives
its own working identity while preserving inherited history and provenance;
copying alone is not a History Generation reset.

The host registers the file/bundle and its database and identifies independent
copying, movement or restoration. UndoKit validates and manages that association.
This requires no user ceremony or UndoKit document-discovery system. A filesystem
copy initially contains copied identifiers; registration must establish the
independent working association before mutation. Requests and recovery bind to
the intended working instance and cannot route into another copy. The host
supplies bindings for copied or shared domain resources.

Creating a new store and opening an existing store have different guarantees.
Opening validates expected store/scope identities, compatibility and recovery
state before enabling mutation. Missing, corrupt, incompatible and temporarily
inaccessible history produce distinct results. Preserve available evidence and
permit safe inspection where possible. A deliberately history-free document is
different from one whose expected history is missing. Fresh-history continuation
uses the explicit recovery/generation-reset contract, never an empty-store
substitution during opening.

## Copying, saving and restoration

Provide a coordinated capture boundary for a coherent copy. Stop admitting new
mutations for affected scopes, finish or reconcile active transactions, and let
the host capture matching domain state, history and required resources. UndoKit
supplies a consistent history snapshot including required journal state. If the
operation affects a whole multi-scope store, its boundary covers those scopes.

An unresolved outcome prevents claiming an ordinary independently editable copy.
The host may preserve a recovery copy containing unresolved evidence. The host
coordinates the domain and history captures; this does not introduce a distributed
atomic database transaction. Ordinary Save retains incremental behavior. A
portable copy requires the stronger coordinated capture boundary.

Folio's existing document lifecycle governs Save, Auto Save, Save As and native
restoration. A move preserves working identity; an independent copy establishes
its own association. Folio-managed restoration is a new accepted change that
retains displaced history as a branch. An external replacement cannot preserve
displaced bytes that no longer exist. These operations must preserve consistent
content, history, resources and journals under their respective contracts.

## Closing, readers and failure isolation

Store closing is explicit and asynchronous. It stops admission, reports queued
requests that never began as unexecuted, and lets delivered work reach a safely
recoverable boundary before releasing resources and ownership.

Successful close means required state and recovery evidence have been safeguarded.
It need not mean that every recovery problem has been resolved: a durably recorded
unresolved transaction may survive closure and be reconciled on reopening. If
required state cannot be safeguarded, close fails explicitly. Folio retains the
responsible host for retry or cancellation under its document lifecycle contract.
Window detachment remains distinct from store closure and never cancels delivered
work by itself.

Recovery Plans are explicitly releasable and bound to an open store session.
Closing or losing that session invalidates its plan handles; reopening requires
new plans. Temporary plan protection may then be reclaimed safely. A plan must
not silently expire while the host remains entitled to use it. Explicit Retention
Holds survive session loss and remain durable until released.

Suspend only the affected scope when an unresolved transaction can be isolated.
Other scopes may continue if the store is sound and their work is independent.
Incompatible schema, lost ownership or inability to write safely may block the
whole store. Maintenance involving shared retained resources respects protected
requirements from every participating scope.

## Compatibility and recovery

UndoKit owns structural store migration under host-selected migration policy.
Hosts own opaque payload interpretation and conversion. Supported upgrades may
be authorized automatically or require an explicit host decision; Folio retains
its user-facing document-upgrade policy.

Preserve a recoverable original while preparing an upgrade, validate the result,
and replace only after successful preparation. Failure leaves the original
usable. Unsupported newer stores remain preserved with a compatibility result.
Opening does not silently rewrite application payloads or discard history.

Automatic recovery is limited to correctness established by stored evidence and
the accepted protocol: reconcile known transactions, complete interrupted
framework operations, or retry after prerequisites return. Never guess a host
outcome, discard unfamiliar records or fabricate continuity. Otherwise preserve
evidence and report available recovery participation: supply missing resources or
codecs, restore a coherent copy, or explicitly adopt current state in a new
History Generation. Repair is not permission to delete history until opening
succeeds.

## Recording, checkpoints and omission

Recording Off preserves transaction safety and changes retention. Existing
history and checkpoints remain subject to their retention policy; switching Off
does not delete them. Once unrecorded edits occur, ordinary Undo cannot cross the
gap. Retained states may still be reconstructed and restored through a new
transaction. Re-enabling recording establishes a baseline at coherent current
host state without reconstructing the missing interval.

Checkpoint success requires its history record and declared dependencies to be
durably secured. The host supplies coherent state and confirms preservation of
required host-owned resources; UndoKit commits the checkpoint and references.
For Folio, the host also ensures the Document is saved. UndoKit does not perform
an application's Save. Recording Off permits checkpoints with the same guarantees.
A failure between steps must remain recoverable without exposing an incomplete
checkpoint as usable.

Explicit Omit History requires coherent current host state and no active or
unresolved transaction. Retire the old History Generation, clear its native
Undo/Redo projection and release obsolete history references. The host removes
its resources only after accounting for current content and other retained
dependencies. A failure reports its actual outcome and preserves recovery evidence;
it must not falsely claim a history-free result. External backups and previously
saved copies remain unaffected.

## Capacity and maintenance

Report UndoKit's complete physical footprint: database files, journals, stored
payloads, protected history, pending recovery and temporary maintenance space.
Distinguish current usage from estimated working headroom. The host accounts for
external resources retained by history and its overall application budget;
UndoKit cannot infer their byte cost from opaque references.

Before refusing a new transaction for capacity, UndoKit may perform bounded,
policy-authorized pruning. Preserve holds, checkpoints, current dependencies and
recovery requirements. If sufficient capacity cannot be established, refuse
before invoking the host and report the limiting condition. Never silently lower
requested Undo depth or override protections to admit work. The host may change
policy, release holds or provide space. An unmet soft retention target alone
remains distinct from a hard safety limit.

Migration, compaction and copying include temporary working space in admission.
Estimate and check the requirement before starting; preserve the original until
the replacement is validated. A check cannot guarantee a later write will succeed.
Space loss during an operation reports failure and leaves a recoverable original.
Finalization failures follow the established outcome-reconciliation protocol.
The accepted [measurement plan](acceptance-measurement-plan.md) supplies candidate
limits, workloads and runner budgets. Production ceilings require measured proof
and review. SQLite theoretical limits are not tested capacity.

UndoKit relies on Core Data and operating-system file services. It does not
classify filesystems or build a replacement file-coordination system. Hosts choose
and access locations and perform their required external coordination. UndoKit
handles reported failures and detected ownership/replacement conflicts while
preserving its transaction guarantees. The proof concerns framework behavior
using platform storage machinery, not universal filesystem qualification.

## Initial proof and handoff

Use a disposable Folio Document host and a bounded KitchenMemory-style app-local
fixture. The initial foreseeable suite covers:

1. Explicit document placement, the persistent default, multiple scopes and
   competing writable ownership.
2. Close/reopen, interruption after host acceptance and recovery isolation.
3. Coordinated capture with active journals, save/copy/move/Save As/restore,
   independently registered copies and inherited history/resource bindings.
4. Supported and interrupted migration, unknown schema/payload/codec, missing
   history, corruption and unavailable stores, with no silent empty substitution.
5. Capacity refusal before delivery, failure during finalization and failed
   maintenance preserving originals and required evidence.
6. Recording Off/On, checkpoints while Off, plan release, durable holds and
   successful/failed omission without loss of current resources.

The measurement plan supplies the failure matrix, scenarios and candidate limits;
measured results remain pending. The package and
compatibility proof is [#49](https://github.com/Folio-Suite/Folio/issues/49),
coordinated with acceptance/recovery, native and retention proofs in #47–#50.
Record actual results, limitations and maintainer review; return failed assumptions
to the design. New discoveries may add focused cases as UndoKit matures. No
production package migration or storage guarantee is established by this document;
#51 remains the design-and-proof acceptance gate.
