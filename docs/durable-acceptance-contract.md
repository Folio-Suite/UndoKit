<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Durable acceptance and interruption recovery

Accepted by the maintainer on 2026-09-28 through
[Folio issue #41](https://github.com/Folio-Suite/Folio/issues/41). This document
defines the protocol boundary that later UndoKit API, storage, native-routing and
proof work must preserve. It is an accepted design, not an implemented API or a
claim that the current framework scaffold provides durable history.

## Purpose and trust boundary

UndoKit is a strict history transaction server. A host owns semantic meaning,
validation, no-op filtering, domain effects, compensation, authoritative
outcomes, recovery evidence and History Policy. UndoKit owns History
Transactions, immutable Action relationships, History Scope ordering, its Core
Data history store, recovery coordination, retention references and storage
safeguards.

UndoKit does not infer whether opaque domain data changed. The host proves an
Accepted Outcome or Rejected Outcome through the framework's strict adapter
contract. A callback, successful return or history-store write alone does not
establish domain acceptance.

The ordinary host interface must remain small. Conceptually, a host submits one
typed semantic Command in a History Scope and receives one of:

- **Accepted**, with a compact receipt for the resulting Action or Undo Group;
- **Rejected**, with an authoritative domain reason and no Action; or
- **Failure**, with a typed cause, protocol stage, History Scope disposition and
  any permitted host recovery participation.

The public API shape, generic types and isolation declarations belong to
[issue #43](https://github.com/Folio-Suite/Folio/issues/43). Hosts never set
internal transaction states, advance Undo/Redo Position or edit UndoKit records.

## Host outcome contract

After UndoKit crosses the host boundary, the host must be able to look up the
Command by its History Scope and stable identity without applying it again. The
authoritative result is exactly one of:

- **Accepted**: the semantic effect definitely occurred and stable evidence
  identifies the result;
- **Rejected**: the semantic effect definitely did not occur; or
- **Unresolved**: neither conclusion can be proven.

A timeout, thrown error, lost connection or missing receipt is not a Rejected
Outcome. Unresolved is a severe invariant or durability failure, not ordinary
control flow. It suspends the entire History Scope: UndoKit exposes no Undo or
Redo and invokes no new tracked semantic mutation until the outcome is
reconciled or the host explicitly begins a new History Generation. Other scopes
remain independent. Diagnosis and evidence-preserving recovery remain available.

For a Core Data host, the expected adapter records a compact Command receipt in
the same host-store transaction as the semantic user-data change. The host may
instead provide an equally authoritative outcome derived from durable domain
state. UndoKit neither owns the host's model or context nor promises a
distributed transaction between the host store and its own history store.

## Identity and retry

A Command identity is permanently bound, while it remains within the host's
declared retention and retry horizon, to one History Scope and one canonical
intent fingerprint. An exact delivery retry preserves that identity. Reusing it
with different intent is a hard conflict and performs no domain work.

Durable preparation returns an UndoKit transaction token containing the History
Generation and server-assigned sequence. Retries present that token. Pruning may
advance the retained transaction boundary; a token behind the boundary is
retired without requiring one permanent tombstone per historical Command. By
authorizing pruning, the host relinquishes retry and Undo/Redo rights for the
retired material.

UndoKit never blindly invokes a Command again after delivery may have begun. It
first queries the authoritative outcome. Accepted and Rejected identities are
terminal. A later user attempt is a new Command. Redelivery with the same token
is permitted only when UndoKit can prove the host was never invoked.

## Serialized transaction lifecycle

Exactly one History Transaction per History Scope may cross the host boundary at
a time. UndoKit may serialize asynchronous callers, but it does not prepare or
invoke the next Command until the active transaction closes. Host callbacks may
not re-enter UndoKit with another Command for that scope. Independent scopes may
proceed concurrently.

The internal durable states are:

1. **Prepared**: UndoKit has atomically stored identity, fingerprint, grouping,
   required recovery data and admission results; the host has not been invoked.
2. **Delivery Started**: this transition commits before invocation. The host may
   or may not have received the Command, so interruption requires outcome lookup.
3. **Accepted, Finalization Pending**: the domain effect is authoritative; only
   history finalization may proceed.
4. **Rejected, Closure Pending**: no domain effect occurred. An original Command
   closes without an Action; a rejected inverse must finalize invalidation.
5. **Unresolved**: authoritative reconciliation failed and the scope is
   suspended.
6. **Finalized**: the Action, position, group relationship or invalidation is
   durably committed.
7. **Retired by Reset**: the host explicitly abandoned the old History
   Generation after adopting one coherent current domain state.

If the host accepts an effect but UndoKit cannot finalize it, the effect remains
accepted. UndoKit preserves the prepared recovery record, suspends the History
Scope and retries finalization only. It neither applies the Command again nor
automatically compensates it.

## Cancellation, rejection and failure

Cancellation is ordinary only before the host boundary:

- before preparation commits, cancellation leaves no durable record;
- after preparation but before Delivery Started, UndoKit closes the prepared
  transaction without invoking the host;
- after Delivery Started, caller cancellation cannot cancel reconciliation; the
  caller may stop waiting, but UndoKit must obtain and finalize an outcome; and
- a host-supported cancellation is Rejected only when the host authoritatively
  proves that no semantic effect occurred.

Process termination, abandoned tasks and lost connections are interruptions,
not cancellation.

Known no-ops should be filtered before submission. The host validates again at
acceptance because reality may have changed. No change, stale preconditions,
validation refusal and policy denial are structured Rejected Outcomes when the
host can prove no effect occurred. Uncertain effects are Unresolved.

A public Failure identifies a broad cause such as storage, compatibility,
capacity, resource availability, host protocol, integrity, cancellation or an
underlying system failure. It also reports the failed stage and one disposition:

- **usable**, when nothing crossed the host boundary or safe closure completed;
- **suspended**, when reconciliation or finalization remains required; or
- **reset required**, when the current generation cannot safely continue.

Failures may identify a narrow host action that could permit recovery. They do
not expose Core Data managed objects or let the host manipulate protocol states.

## Actions, compensation and invalidation

Every accepted semantic effect submitted for retained History creates a new
immutable Action. An accepted ordinary Command creates an Action; accepted Undo
creates a compensating Action linked to the complete target Undo Group; accepted
Redo creates a reapplication Action linked to the compensation and original
group. Earlier Actions are not rewritten. Undo/Redo Position changes only after
the new Action and relationships finalize. Rejected and Unresolved attempts
create no Action. Recording Off follows the same safe transaction protocol but
does not retain an ordinary durable Action after finalization.

An Undo Group is one semantic transaction from the user's perspective. UndoKit
prepares one identified group compensation containing the ordered member plan.
The host accepts or rejects the group as a whole and supplies member evidence
under one authoritative group outcome. If a host cannot provide all-or-nothing
semantics, those members cannot form one Undo Group. Partial application is
Unresolved and suspends the scope.

When an inverse is authoritatively rejected, the affected group becomes
ineligible according to the host's declared semantic dependency scope. UndoKit
must finalize that structural invalidation before exposing later availability.
If the invalidation write fails, the prepared inverse remains a fail-closed
recovery fence. Reopening suspends the scope instead of resurrecting stale Undo
or Redo.

## Core Data and bounded inputs

Core Data is the selected UndoKit persistence engine. Protocol-critical
structure—Commands, Actions, groups, ordering, outcomes, pruning and retention
relationships—will use normalized managed records. Swift Collections and Swift
Algorithms are permitted for suitable in-memory representation, traversal and
validation. Explicit ordinals and uniqueness constraints remain appropriate
where deterministic ordering matters. Versioned binary or Codable envelopes are
reserved for genuinely opaque, bounded host payloads.

SwiftData is not selected. It does not remove the need to decompose normalized
collection structure, remains under active development and does not currently
provide enough concrete benefit to displace the conservative Core Data choice.

Preparation is one ordinary atomic history-store transaction. It verifies only
what UndoKit can honestly know: that its store is open, compatible and writable;
that the prepared record can be committed; that configured retention and
capacity policy is not already exceeded; and that known encoding and structural
requirements pass. UndoKit relies on Core Data's transaction and storage
machinery rather than reimplementing a database or promising that a later write
cannot fail.

Inputs use two tiers of safeguards:

- generous advisory thresholds accept the operation while reporting unusual
  payload size, group cardinality, decoding cost or store growth; and
- measured hard ceilings reject pathological inline payloads, group totals,
  member counts, queue depth, decoded collection/nesting size or materialized
  validation data before the host is invoked.

Hosts may select stricter policy but cannot exceed the framework's compiled
safety ceiling. [Issue #46](https://github.com/Folio-Suite/Folio/issues/46) will
choose numbers from representative Folio and KitchenMemory workloads.

## Retention Stores and large objects

Large images, attachments, fonts and other domain objects remain in host-owned
stores. UndoKit retains bounded references rather than copying their bytes into
history payloads. A host may identify multiple Retention Stores with different
storage technologies and policies; UndoKit does not define their nature.

A Retention Store uses a stable UUID-backed identity. A Retained Object Reference
combines that store identity with a bounded canonical object key and, when
required, a version or digest. UUID is the preferred object-key representation;
bounded canonical UTF-8 strings and versioned bytes support specialized hosts.
The public wrapper may be comparable for deterministic listing. UndoKit does not
persist arbitrary runtime `Comparable` objects.

References are normalized relationships belonging to Actions, branches,
checkpoints and recovery records in UndoKit's unified store. UndoKit provides:

- an on-demand distinct collection of every required object identity for a
  Retention Store, aggregated across all participating History Scopes, with
  optional reference counts or reasons; and
- a stable maintenance operation that serializes reference changes for one
  Retention Store while supplying the required-object collection so the host can
  perform its own atomic cleanup transaction.

Ordinary inspection may use a snapshot. Destructive cleanup uses the stable
maintenance operation so a new History Transaction cannot add a reference after
the host decides an object is unneeded. History pruning removes its associated
references in the same UndoKit transaction. The collection is derived from the
history graph, never maintained as a second mutable ledger. Shared, current,
checkpoint and recovery-required objects remain listed.

## Recording, pruning and generation changes

Recording Off changes retention, not transaction safety. UndoKit still performs
prepare, host acceptance and finalization, but does not retain an ordinary
durable Action for reopening. Native session Undo may receive the accepted
operation through the later routing adapter. Recovery data remains only until
safe closure. Named checkpoints remain separately available. Re-enabling
recording establishes a new baseline and does not claim the unrecorded interval
as History.

Partial policy-authorized pruning remains within one History Generation. It may
remove Actions and references only when current state, retained History,
checkpoints and pending recovery no longer require them.

Complete clearing is an explicit generation transition. With no active or
Unresolved transaction, the host adopts one coherent current state as a new
baseline. UndoKit atomically retires the old generation, clears its native
Undo/Redo projection, removes no-longer-required references and requires clients
to reattach. The operation may create the first new checkpoint atomically.
Backups, native Document Versions, exports and host-owned data are unaffected.

An irrecoverable Unresolved outcome uses the same explicit generation boundary
but is not ordinary clearing. The host acknowledges the lost historical
continuity and adopts current domain reality. UndoKit preserves or quarantines
the failed store and recovery evidence when possible; it never silently converts
Unresolved into Rejected or Finalized.

## Host-assisted recovery

UndoKit reports typed recovery conditions and accepts only narrow recovery
operations. A host may free capacity, restore an unavailable dependency, install
a compatible codec, provide its authoritative outcome evidence or explicitly
request a new History Generation. It never edits UndoKit's managed records or
declares them finalized.

The allowed terminal paths are reconciliation and finalization, restoration of
a missing prerequisite followed by retry of the UndoKit transition, preserved
suspension with quarantined evidence, or explicit generation reset. Exact repair
algorithms belong to store-lifecycle design in
[issue #45](https://github.com/Folio-Suite/Folio/issues/45).

## Documentation contract

UndoKit's eventual public DocC is normative for callers and must meet
[ADR 0008](../../docs/adr/0008-public-api-quality-kit-documentation.md). Every
public symbol documents ownership, isolation, ordering, reentrancy, cancellation,
durability, results, failure disposition, recovery responsibility, limits,
compatibility and potentially expensive behavior. Implemented workflows include
accurate ordinary and failure examples. CI validates the built catalog and
public-symbol coverage as interfaces arrive.

## Required proof handoff

This decision requires later scenario and prototype tickets to cover:

1. interruption before and after every durable protocol transition;
2. host acceptance followed by UndoKit finalization failure;
3. authoritative no-op, stale-input and policy rejection;
4. Unresolved outcome, later reconciliation and explicit generation reset;
5. duplicate delivery and identity/fingerprint mismatch;
6. complete-group Undo/Redo acceptance, rejection and attempted partial result;
7. rejected inverse, failed invalidation persistence and relaunch;
8. cancellation at each permitted and forbidden boundary;
9. Recording Off, relaunch, re-enable and checkpoint creation;
10. partial pruning and complete clearing with reference-set changes;
11. multiple History Scopes sharing multiple Retention Stores during cleanup;
12. advisory warnings and hard-limit rejection before host invocation;
13. missing resources, incompatible payloads, unavailable stores, failed
    migration, disk exhaustion and damaged history; and
14. host-assisted repair, permanent suspension, quarantine and reset-required
    disposition.

[Issue #46](https://github.com/Folio-Suite/Folio/issues/46) turns these into
bounded fixtures and measured budgets. [Issue #47](https://github.com/Folio-Suite/Folio/issues/47)
proves interruption recovery and failed invalidation with disposable stores.
Compilation, behavioral tests, native observations and human acceptance remain
distinct evidence.

## Deferred decisions

This contract does not select public generic signatures, payload codecs, Core
Data entities, migration stages, branch algorithms, native UndoManager routing,
package layout, numerical budgets or repair implementations. Those remain with
issues #42–#50. External Objective-C and XCFramework distribution remains
deferred beyond Folio 1.0.
