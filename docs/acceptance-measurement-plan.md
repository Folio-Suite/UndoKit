<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Acceptance scenarios and measurement plan

Accepted by the maintainer on 2026-09-29 through
[Folio issue #46](https://github.com/Folio-Suite/Folio/issues/46), following
20 decisions and final agreement. This plan turns the accepted
[transaction](durable-acceptance-contract.md),
[retention](history-retention-contract.md),
[interface](typed-interface-contract.md),
[native-routing](native-routing-contract.md) and
[storage](store-lifecycle-contract.md) contracts into bounded proof work.
No new runtime evidence or production limits are established by accepting it.

## Acceptance rules

Correctness and preservation are mandatory. The ordinary Folio, bounded
KitchenMemory and large-payload workloads must behave correctly, including
rejection and recovery. Multi-GiB payloads are exploratory stretch cases.

Timing figures below are initial measurement targets, not binding pass/fail
thresholds. Missing them prompts investigation; meeting them does not excuse
an interaction that feels slow. Extreme operations are judged on their merits,
with realistic expectations and the maintainer's review of actual behavior.
A disappointing result remains open for improvement or an explicitly accepted
limitation. Do not silently revise targets after measuring them.

Resource targets and candidate request limits are distinct from validated
production safety ceilings. The prototypes measure and calibrate them; the
maintainer reviews any revision before #51 accepts the implementation contract.
An unrun case is never passed. Broad platform certification, external binary
distribution and Objective-C consumers remain deferred beyond Folio 1.0.

## Reference environment and reproducibility

The initial reference laptop is an Apple M3 Pro (11 logical CPUs), 18 GiB RAM,
arm64, running macOS 27.0 (26A428) and Apple Swift 6.4. Each report records the
actual hardware, OS, toolchain, source revision and build configuration used.
Evidence on this machine does not establish macOS 14 or Intel performance.

Run three independent repetitions per mandatory fixture with deterministic
seeds. Measure at least 1,000 small operations per run in an appropriate small-
operation phase; report that phase separately from bulk payload processing.
Report p50, p95, p99 and maximum latency, peak memory and full disk footprint.
Use ten fresh-process reopen measurements per fixture and report every result.
Do not describe a fresh process as a cold filesystem cache.

Record exact generated distributions, seeds, branch topology, Actions per group,
checkpoint representations, resource bindings and encoded sizes. Fixture creation
is observable work, with its costs recorded separately from steady-state work.
No existing production scale benchmark is inherited: #43's 4096-byte fixture
ceiling and tiny codec-size examples were interface evidence only.

## Mandatory workloads

| Fixture | Accepted starting workload |
| --- | --- |
| Ordinary Folio editing | 10,000 retained groups; roughly 1 KiB encoded data per group with occasional groups up to 1 MiB |
| Large Folio history | 100,000 retained groups across 100 branches, 100 checkpoints, mixed small text and larger structural operations |
| KitchenMemory-style history | 10,000 successive submissions, a 100-group ordinary Undo/Redo allowance, several independent scopes |
| Large-payload bounded history | 100 retained groups averaging 8 MiB encoded data each, approximately 800 MiB before database overhead |

Count all encoded Command and accepted-effect data in group sizes. Include
multi-Action groups, protected history and shared retained-resource references.
Bulk attachments remain in host-owned resource stores. The bounded app-local
case must exercise turnover and pruning. The large history case exercises
traversal and reconstruction rather than insertion alone. 100,000 groups is a
mandatory test size, not a supported-history maximum.

The large history fixture must reconstruct a state near the beginning from near
the end and a distant state on a divergent branch whose common ancestor is near
the beginning. Then return to the state left behind. Exercise detailed retained
history and a variant where consolidation requires a checkpoint baseline. Verify
exact resulting states, retained resources and preservation of displaced history.
Report records visited, bytes read, first useful response and total completion.

## Large payload exploration and adapter boundaries

Attempt 1 GiB payloads, then larger sizes up to 4 GiB, if runner resources permit.
This range is an exploratory hypothesis, not a supported limit. Multi-GiB objects
and enormous object graphs are exceptional; mandatory acceptance does not depend
on succeeding with a 3+ GiB changeset.

Ordinary codecs may use in-memory values. Enormous history payloads require a
proven bounded-memory transfer path, such as file-backed or streamed encoded data,
if the experiment justifies adding it. Until then, refuse oversized in-memory
submissions explicitly. History bytes owned by UndoKit remain distinct from
host-owned retained resources.

Measure adapter peak memory as well as framework memory. Streaming into UndoKit
must not hide an earlier enormous marshal/unmarshal allocation. UndoKit bounds
encoded size and its own structures. Framework-supplied codecs enforce their
documented decoding safeguards; custom host codecs enforce their own structural
and allocation limits. UndoKit does not interpret opaque internal subobjects.
Reject known excessive sizes or structure without fully expanding them merely
to discover the excess. Test realistically huge requests; pathological requests
should receive controlled refusal rather than exhaust the laptop.

## Runner safeguards

| Resource | Default experiment limit |
| --- | --- |
| Combined probe and fixture-host peak memory | 2 GiB |
| Temporary disk footprint, including journals and staging copies | 12 GiB |
| Remaining free disk | Leave at least 20 GiB; skip a case whose estimated working space crosses this floor |
| Runtime | Ten minutes per scale case, including fixture construction |
| Heavy-case concurrency | One at a time |

Increase workloads in stages. A watchdog stops an over-budget case and preserves
its diagnostic report, including the phase and completed work. The maintainer
may authorize a specific run beyond defaults; record that override with the
results. Such authorization does not change production limits.

A mandatory workload exceeding these budgets requires review before acceptance.
A resource-limited stretch case records the experimental boundary and untested
coverage. Test limit enforcement with small fixtures and deliberately lowered
limits; filling the real disk or allocating GiB is unnecessary for refusal tests.

## Initial timing targets

Separate queue waiting, framework preparation/finalization, host execution or
reconstruction, and end-to-end completion. Use deterministic lightweight host
fixtures. Record delayed callbacks and large operations separately from ordinary
small-operation percentiles. Observe native responsiveness during long work.

| Operation | Initial target |
| --- | --- |
| Small-operation framework preparation plus finalization | p95 ≤ 20 ms; p99 ≤ 50 ms |
| Small-operation end-to-end completion, lightweight host and empty queue | p95 ≤ 50 ms; p99 ≤ 100 ms |
| Synchronous native bridge segment on main thread | ≤ 8 ms |
| Clean reopen to availability, ordinary/bounded fixture | ≤ 500 ms |
| Clean reopen to availability, 100,000-group fixture | ≤ 2 seconds |
| Page of 100 lightweight history entries, ordinary/bounded fixture | p95 ≤ 50 ms |
| Same page, 100,000-group fixture | p95 ≤ 100 ms |
| First Recovery Plan batch, ordinary/bounded fixture | p95 ≤ 100 ms |
| First Recovery Plan batch, 100,000-group fixture | p95 ≤ 250 ms |

Always report maxima and investigate outliers. Measure interruption recovery
separately from clean reopen. Initial availability and history browsing must not
decode the whole payload collection. Measure full reconstruction by records and
bytes consumed. If an extreme operation feels slow, identify traversal, decoding,
host reconstruction, I/O or unnecessary work before judging the result.

The host owns prompts, progress indicators and Cancel controls. UndoKit provides
progress/cancellation hooks where work can be measured, without invented
percentages. The interface promptly acknowledges work and keeps navigation and
scrolling responsive. A normal busy indicator is acceptable; an unresponsive-app
beachball is not evidence of acceptable asynchronous behavior.

Before restoration submission, cancellation stops further reconstruction at
bounded cancellation points, releases the Recovery Plan and leaves current state
unchanged. Host decoding/reconstruction must cooperate. After submission, existing
transaction cancellation rules apply; after delivery, cancellation cannot imply
rollback or remove outcome-reconciliation obligations. The UI distinguishes
stopping preparation from acceptance already underway.

## Memory and disk efficiency targets

Additional peak memory above the initialized fixture host should remain within
256 MiB for ordinary Folio, bounded KitchenMemory and large-history fixtures,
and within 512 MiB for the mandatory 800 MiB payload fixture.

After maintenance, target owned history storage of at most twice the retained
encoded payload bytes, plus 4 KiB per retained Action and 32 MiB fixed allowance.
Measure peak usage separately, including journals, migration/copy staging and
maintenance headroom. Report host-owned retained resources separately. These are
initial efficiency targets, with explicit evidence-based revision permitted.

## Candidate prototype request limits

| Dimension | Initial candidate |
| --- | --- |
| Ordinary in-memory encoded payload | 32 MiB per payload |
| Total encoded payloads in a group | 64 MiB |
| Actions in a group | 4,096 |
| Retained-resource references in a group | 65,536 |
| Waiting queue per scope | 64 requests or 64 MiB encoded data, whichever comes first |
| Presentation metadata | 64 KiB per record |
| History page | Up to 256 entries, additionally bounded by returned bytes |

These are adjustable prototype settings, not measured production safety claims.
Test below, at and above boundaries, using smaller configured limits where useful.
The page byte bound must be explicit in each experiment's configuration and report;
this agreement selects no production numeric value for it. The exploratory
file-backed path has separately configured limits and bypasses no group, reference
or recovery safeguards. Adapter decoding limits remain adapter responsibilities.

## Finite scenario matrix and proof ownership

| Requirement family | Required demonstration | Owning proof |
| --- | --- | --- |
| Acceptance and interruption | Before/after preparation, delivery, host acceptance, finalization, inverse acceptance and retry; stable identities and authoritative outcome lookup | #47 |
| Rejection and invalidation | No-effect rejection, failed invalidation writes, unavailable evidence, no false Redo or resurrected eligibility | #47 |
| Group and scope safety | Whole-group effects, no duplicate acceptance, repeated reopen, isolated unresolved scopes, store-wide failures | #47, #49 |
| Typed evolution and independence | Independent Swift consumer, actor boundaries, separate Command/effect payloads, supported codecs, malformed/unknown data | Existing #43 evidence, affected checks rerun; #49 for persistent compatibility |
| Native routing | Real menus, keyboard, text grouping/local focus, two documents/multiple views, names, dirty state, notifications, pending barriers, rejection, detachment and both directions restored | #48 |
| Store and package lifecycle | Explicit/default placement, multi-scope ownership, active journals, save/copy/move/Save As/restore, independent registration and resource bindings | #49 |
| Failure preservation | Interrupted migration, unknown schema/codec, corrupt/missing/unavailable stores, refusal before acceptance and write failure after preflight | #49 with #47 recovery evidence |
| Recording and omission | Off/checkpoints/On, successful and failed omission, generation changes preserving current resources | #49 |
| Branches and reconstruction | Abandoned futures, distant divergent restoration and return, selected-material recovery and exact expected states | #50 |
| Retention and scale | Checkpoints, holds, complete groups, consolidation, gaps, pruning, protected recovery/resources, plan release and full-footprint measurements | #50, lifecycle cases in #49 |

Use deterministic injected failures at every agreed transaction boundary, plus
actual process termination and reopening for representative cases. Include host
acceptance before finalization and failed invalidation. Reopen repeatedly to
verify stable recovery. Exceptions alone do not prove process-interruption
behavior. An independent expected-state model checks no duplicate effects, false
Redo, revived invalidation, partial groups or lost protected resources.

The four proofs may share small disposable utilities, with separate evidence:

- [#47](https://github.com/Folio-Suite/Folio/issues/47): separate on-disk host and
  Core Data history stores, authoritative receipts, failure injection and restart.
- [#48](https://github.com/Folio-Suite/Folio/issues/48): real AppKit document host,
  menus, keyboard commands, text controls and multiple windows; bounded secondary
  consumer policy remains distinct from Folio navigation.
- [#49](https://github.com/Folio-Suite/Folio/issues/49): disposable packages with
  active journals, resource files and schema/payload fixtures, plus an app-local
  multi-scope example.
- [#50](https://github.com/Folio-Suite/Folio/issues/50): persisted history
  representation, deterministic workload generator and independent expected-state
  model for branching, restoration and pruning.

## Closure evidence

All four proofs remain required. No proof is retired by this agreement. Every
report retains setup, source revision, exact scenarios, actual results, artifacts,
limitations and authorized resource overrides. Keep compilation, automated
behavioral tests, native observations and maintainer acceptance distinct.

Reuse only the evidence actually established by the #43 interface proof; rerun
affected checks if interfaces change. No native/storage/scale evidence is inferred
from its compilation or codec checks. Each proof requires maintainer review before
closure. Failed assumptions return to their owning design decision. Unrun and
resource-limited stretch cases are never marked passed.

Prototypes remain disposable, without Folio production-package migration.
[#51](https://github.com/Folio-Suite/Folio/issues/51) reconciles the accepted
contracts and measured evidence before the production implementation handoff.
