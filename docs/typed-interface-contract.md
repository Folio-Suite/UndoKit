<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Typed host interfaces and opaque payloads

Accepted by the maintainer on 2026-09-29 through
[Folio issue #43](https://github.com/Folio-Suite/Folio/issues/43), following the
isolated Swift interface proof. Binary property-list encoding was accepted as
an additional convenience representation and verified in the extended proof.

This contract builds on [durable acceptance](durable-acceptance-contract.md) and
[history retention](history-retention-contract.md). It defines the interface
responsibilities and evidence required by later implementation. The production
framework remains a scaffold; prototype declarations are illustrative rather
than a shipped or frozen public API.

## The host adapter

UndoKit provides a specialized transaction store and a directed acyclic history
graph. The graph describes accepted historical relationships; prepared requests,
unresolved outcomes and recovery fences also require durable representation.
Storing a request does not establish an accepted Action.

A thin host-owned adapter translates between natural application operations and
UndoKit's application-neutral transaction protocol. Application model objects
need not inherit framework classes, conform to history protocols or be manually
decomposed into a generic object graph. The adapter can be small, but must meet
the substantial host acceptance and recovery guarantees in #41.

Register each independently defined operation family under a stable identifier,
with its typed payloads, versioned codecs and host execution, compensation,
reapplication and outcome-lookup behavior. The host chooses the granularity:
separate text-replacement and Content Unit movement operations are possible,
as is one enum or a complete organization command containing coordinated members.
Registrations are rebuilt from application code when reopening; runtime closures,
model instances and actor instances are not persisted as history.

UndoKit owns preparation, history ordering and relationships, grouping,
finalization, recovery coordination and storage safeguards. Hosts own domain
meaning, validation, no-op filtering, effects, compensation, authoritative
outcomes and evidence. Atomic group semantics remain those of #41; registration
does not make independently committed effects atomic.

## Typed data, opaque storage and results

The typed Command and the host's accepted-effect payload may have different
types. For example, an intention to replace text differs from the actual prior
and resulting text needed for compensation. Simple operations may reuse one
type. The host determines what evidence and dependencies faithfully describe
the accepted effect and must preserve authoritative evidence if history
finalization is interrupted.

UndoKit identifies, orders, links, safeguards and checks the integrity of opaque
payloads. It does not interpret text, recipes, draft eligibility or other domain
content. Domain-specific caller results and rejection explanations stay on the
application side of the adapter. Returning data to an application caller does
not implicitly make it persistent history or recovery evidence.

The outer submission result remains Accepted, Rejected or structured Failure.
Accepted supplies a framework receipt after history finalization. Rejected
means authoritative no-effect and creates no Action; its domain explanation is
host-owned. Failure supplies the cause, protocol stage, scope disposition and
permitted recovery participation required by #41. The host's outcome-lookup
protocol reports Accepted with bounded evidence, Rejected without effect, or
Unresolved. These host outcomes are distinct from successful framework completion.

A thrown callback after possible delivery cannot establish rejection. Accepted
host effects followed by finalization failure remain accepted and require
reconciliation/finalization. The proof's transport-level throws do not replace
these production rules.

## Isolation, completion and the waiting queue

The primary submission interface is asynchronous. Callers await one operation
rather than drive transaction stages or poll. Successful completion follows
finalization, not merely host execution. Cancellation and interruptions retain
the boundaries defined in #41; stopping a caller's wait after delivery does not
cancel reconciliation.

The host adapter owns its domain isolation. Main-actor and other actor-owned
models remain where they belong. Typed encoding and decoding occur on the
host side; bounded encoded data, identities and references cross into UndoKit's
own execution and storage machinery. Ordinary host values need not all become
Sendable. The production interface must preserve strict concurrency checking
without unchecked sendability or unsafe isolation escapes.

UndoKit provides a bounded in-memory waiting queue per History Scope. The host
establishes its intended submission order through an ordered path. UndoKit
preserves admission order and permits only one transaction in a scope to cross
the host boundary at a time. It does not infer intended order among independent
concurrent callers. Actor isolation alone is insufficient to guarantee FIFO
across suspension points; the queue is explicit framework behavior.

Queue admission is scheduling, not a durability receipt. A crash may lose
requests still waiting for preparation. UndoKit durably prepares a transaction
before invoking the host, and does not prepare the next transaction until the
active transaction closes. The host preserves its own working document and
provisional input; UndoKit is not the host's write-ahead log. An accepted host
effect is not permitted to lose its tracking guarantees under this queue rule.

A full queue reports failure before the request reaches the host. An ordinary
authoritative rejection is finalized, then the next request may proceed with
its own host validation. UndoKit cannot infer semantic dependencies between
opaque Commands. Operations that must succeed together require an explicit
atomic grouping contract. Unresolved outcomes or incomplete finalization suspend
the scope and prevent subsequent host execution. The accepted
[native-routing contract](native-routing-contract.md) defines native invocation,
editing barriers and bridge/host responsibilities. The
[store-lifecycle contract](store-lifecycle-contract.md) defines storage ownership,
closing and capacity handling. The [measurement plan](acceptance-measurement-plan.md)
supplies candidate queue limits requiring calibration; concrete native integration
requires #48 proof.

## Codecs, identity and evolution

Persist stable host-defined operation/payload identifiers and explicit schema
versions, independent of Swift type names. Renaming a Swift type alone must not
break its history. Hosts register the codecs and versions they can interpret.

Provide explicitly selected Codable conveniences for JSON, XML property lists
and binary property lists, plus host-configured and entirely custom codecs.
Each representation has an explicit codec identity and configuration. Document
supported values and strategies: Codable conformance does not mean every value
fits every representation. In the proof, JSON's default codec rejects non-finite
floating point. XML property lists do not implement an arbitrary XML vocabulary
or Folio's archival XML format.

The host supplies a stable fingerprint of canonical Command intent. UndoKit
compares that fingerprint when enforcing identity and retry binding. Separately,
UndoKit checks stored-byte integrity. A helper may hash a host's canonical intent
encoding; ordinary serialization is not assumed canonical. Codec changes must
not silently redefine an unresolved Command's identity or original fingerprint.
The prototype hash and codec settings are evidence, not a selected universal
fingerprint format.

By default, a host codec interprets old payload versions when reading while
preserving the original stored bytes, schema identity and fingerprints. Unknown
or malformed data produces an explicit compatibility/integrity failure and
remains preserved; UndoKit must not guess its meaning or silently discard it.
Browsing structural history remains possible without decoding every payload.

Persistent payload migration is explicit maintenance with failure preservation,
not a side effect of opening or browsing. Hosts own payload meaning and version
adaptation; UndoKit owns its structural storage migrations. A host may explicitly
choose a History Generation reset as part of a document upgrade, subject to #41's
current-state, active-transaction and unresolved-recovery safeguards. Unknown
payloads do not themselves authorize automatic reset.

## Queries, metadata and reconstruction

Return immutable structural history descriptions separately from payloads:
identities, ordering, groups, relationships, payload type/version identifiers,
recording timestamps and availability. Queries use bounded pages or batches;
payload retrieval and expensive reconstruction are explicit. An ordinary query
must not materialize the entire graph or reconstruct historical domain state.

Hosts may attach a bounded encoded presentation-metadata value, independently
retrievable and interpreted only by the host. Examples include a short label or
small preview; larger resources use Retained Object References. Unknown or absent
presentation metadata permits a generic entry without making otherwise valid
history unrecoverable. Anything necessary for recovery belongs among protected
recovery data and dependencies, even if it is also useful for display.

Ordinary reads access committed history independently of the mutation queue.
They never expose partially finalized transactions as accepted history. A
multi-query reconstruction requests a stable Recovery Plan for a selected target.
The plan identifies the baseline, ordered records and declared dependencies and
provides lightweight references incrementally. Required records and resources
remain protected for the plan's duration, until completion or release.

A plan need not begin at the current Undo/Redo Position. Consolidation may have
removed intervening edits while retaining a recoverable checkpoint. The host
declares reconstruction relationships and sufficiency; UndoKit follows their
structure and safeguards dependencies rather than interpreting opaque content.
The host retrieves, reconstructs and validates the state before submitting a
new restoration transaction. Reading or consuming a plan does not move the
active position. The store-lifecycle contract makes plans explicitly releasable and bound to an
open store session, with handles invalidated on session loss or closure. Explicit
Retention Holds remain durable. Numeric limits and scale proof remain pending;
no unlimited read hold is implied.

## Public dependencies and documentation

Public interfaces use standard Swift/Foundation and UndoKit-owned types.
Collections and Algorithms may support internal machinery when a concrete
benefit warrants them; they are not imposed through public queue or graph types.
Hosts remain free to use their own collection types and codecs. This does not
promise persistence of arbitrary runtime objects.

The public DocC obligations in #41 remain normative: ownership, isolation,
ordering, cancellation, completion, durability, failures, recovery, limits and
potentially expensive operations must be documented. Swift module independence
is required. External Objective-C and binary-distribution work remains deferred
beyond Folio Suite 1.0.

## Current implementation note

Public typed contracts and forwarding methods remain in `UndoKit/Interface/`.
`UndoKit/Modules/HostAdaptation/` owns codec execution, registration binding and
validation, version selection, typed delivery and outcome conversion, and opaque
family routing. Registration construction derives persisted operation and codec
identity/configuration from the codec values. It rejects empty identities,
nonpositive current versions, and invalid older-version mappings with an
admission `invalidInput` failure. Main-actor and actor handlers receive a
`HistoryOperationContext` containing the transaction token and optional
restoration origin; typed Commands carry restoration origin and presentation
metadata, and accepted typed effects carry retained resources. A typed callback
that cannot establish an authoritative result returns unresolved. In particular,
encoding accepted-effect evidence after a host mutation has no durable proof on
its own: the host must preserve evidence atomically with its semantic change, and
a failure to produce the callback evidence cannot be turned into rejection.

The compile-only independent consumer demonstrates a main-actor registration,
codec-derived metadata, typed submission and checkpoint state conversion. Its
handler returns unresolved because that sample has no semantic store or durable
outcome receipt. This is interface coverage, not runtime or performance evidence.

## Accepted feasibility evidence and handoff

The disposable proof is preserved separately from main on
`codex/prototype-undokit-interface-43`:

- [Report and caller sketches](https://github.com/Folio-Suite/Folio/blob/9b8879d01ba12da5db755858d7754670236b0c92/UndoKit/prototypes/typed-interface/README.md)
- [Captured 50-check run](https://github.com/Folio-Suite/Folio/blob/9b8879d01ba12da5db755858d7754670236b0c92/UndoKit/prototypes/typed-interface/results.md)
- [Source and runner](https://github.com/Folio-Suite/Folio/tree/9b8879d01ba12da5db755858d7754670236b0c92/UndoKit/prototypes/typed-interface)

Apple Swift 6.4, Swift language mode 6, complete concurrency checking and warnings
as errors passed on the current arm64 macOS host. Separate writer and reader
processes exercised rebuilt registrations. A main-actor text adapter and a
background-actor organization adapter retained non-Sendable domain objects.
The custom-coded organization Command did not require Codable conformance.

The checks cover separate Command/effect payloads; JSON, XML/binary property-list
and custom codecs; old-version interpretation without rewriting source bytes;
compensation and outcome lookup; malformed/unsupported payloads; integrity and
fixture-size failures before semantic application; opaque metadata; host resource
references; and module resource-bundle lookup. A deliberately unsafe actor
crossing was rejected by the compiler. These establish interface feasibility.

The tiny sample used 42 JSON bytes, 281 XML property-list bytes and 83 binary
property-list bytes. This is a footprint observation, not a benchmark or a
universal efficiency ranking. The accepted measurement plan requires representative
workload measurements in the subsequent proofs; the
4096-byte fixture ceiling is not a proposed production limit.

Resource lookup used an explicit fixture, not a real Core Data history model.
No production persistence, FIFO/backpressure, retry binding, crash recovery,
native Undo routing, Recovery Plan execution, pruning protection, scale or
macOS 14/Intel runtime behavior is established by this proof. #44 defines the
accepted native behavior and #45 defines storage lifecycle. #46 defines the
measurement plan; #47–#50 retain runtime proof and limit calibration; #51 remains the design-and-proof acceptance
gate before Folio durable-history implementation. Closing #43 accepts the host
interface contract and its stated evidence limits, not a production engine.
