<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Branches, checkpoints, and history retention

Accepted by the maintainer on 2026-09-29 through
[Folio issue #42](https://github.com/Folio-Suite/Folio/issues/42). This contract
extends the [durable-acceptance contract](durable-acceptance-contract.md).
It records agreed behavior for later API, storage, routing and proof work;
the current framework scaffold does not implement these capabilities.

## Restoration and ordinary traversal

Browsing retained History changes neither domain state nor Undo/Redo Position.
Returning to a Historical State uses restoration: a new Command establishes
that state as an accepted, undoable change with its origin recorded. This is
the operation for both interactive and programmatic callers. There is no
separate operation to resume editing by selecting an old branch and position.

For states A → B → C, restoring A establishes A's content through a new accepted
change after C. The next ordinary Undo returns to C; Redo reapplies the
restoration. Both follow the durable acceptance protocol and retain their
Action relationships. Restoration preserves the displaced continuation and
the order of accepted Commands rather than reattaching the active position
to A's historical predecessor.

Editing after Undo preserves the abandoned continuation as a History Branch,
even when ordinary Redo is no longer available. Preserving that branch does
not exempt it from subsequent authorized retention policy. Restoration itself
must not silently discard displaced work.

Recovering selected historical material likewise creates a new undoable change
with provenance; it does not require restoring the whole state. The host owns
semantic completeness, validation and compensation for every such operation.

## Undo depth and eligibility

A bounded Undo depth counts complete logical Undo Groups in the current
Undo/Redo ordering. Undo and Redo share that allowance: with 100 groups and
20 undone, 80 groups remain on the Undo side and 20 on the Redo side.
Compensating and reapplication Actions are durable accepted records, not
additional depth units. Repeated Undo/Redo does not consume the allowance
without new editing. Group reversal and reapplication remain all-or-nothing.

Undo depth is independently configurable from retained historical material.
Older held states and detailed segments do not add ordinary Undo levels;
recovering them is a new accepted change. KitchenMemory's at-most-100-group
policy remains a host policy and possible convenience configuration, not a
framework-wide default, total-history bound or byte/performance budget.
Simple hosts can configure bounded Undo; Folio can specify richer retention
requirements. No universal numeric default is selected here.

If a group becomes permanently ineligible, earlier groups may remain available
only where the host explicitly establishes their independence and eligibility.
UndoKit never infers that assurance from graph position. Without it, traversal
stops at the affected boundary. This exceptional recovery behavior does not
permit partial group reversal or bypass the scope suspension required for
Unresolved outcomes. Invalidated groups do not become eligible merely because
similar data values later reappear.

## Checkpoints and separate retention holds

A retained Checkpoint guarantees recovery of one coherent Historical State and
its required dependency versions. It does not automatically preserve the
individual edits that produced that state. An application can retain a finished
chapter while allowing its preceding hundreds of edits to be consolidated.

Applications distinguish automatically managed checkpoints from explicitly held
states. A Retention Hold protects its designated state or detailed history
segment from automatic pruning until the hold is explicitly released. Being a
Checkpoint alone does not require permanent retention. Releasing a hold makes
the material subject to the remaining requirements and application policy.

A state hold preserves faithful state recovery. A separate history hold
preserves a precisely identified sequence of complete Undo Groups, including
its Action identities, order, grouping and the data needed to traverse it.
Protecting a sequence does not implicitly protect detailed side branches;
applications can protect additional sequences explicitly. Dependencies needed
to satisfy any retained promise remain required regardless of branch location.

## Host policy and safe pruning

Applications declare the ordinary Undo depth, Historical States and detailed
segments they require. UndoKit computes the supporting history and dependency
relationships, determines what is eligible for pruning and executes safe
pruning. A simple depth configuration produces requirements through the same
mechanism. Hosts need not reproduce the framework's dependency logic.

Folio may choose a schedule such as a month of detailed edits, daily checkpoints
for a quarter, and weekly checkpoints thereafter. Those intervals illustrate
host policy; this contract does not adopt them as defaults or select a
scheduler. Integration with Apple's Time Machine remains a future possibility,
not an accepted implementation requirement.

Retention targets and hard resource limits have different effects. If holds
require 150 historical groups when the host targets 100, UndoKit preserves the
protected material and reports that the target cannot be met. This does not
increase a separately configured 100-level ordinary Undo allowance. A hard
limit may prevent acceptance of further edits, but cannot silently revoke a
hold. Applications manage total storage assumptions and decide whether to
release protection, increase capacity or take another action. Preparation and
post-acceptance write failures retain the durable-acceptance contract's rules.

Pruning must preserve requirements of current state, ordinary Undo/Redo,
retained states and segments, holds, and pending recovery. Removal of history
and its retention references occurs in the same UndoKit transaction; host
object cleanup uses the existing serialized retention-maintenance operation.
Partial pruning remains in the same History Generation. Explicit complete
clearing and omission retain their separately defined semantics; neither is
an automatic response to an unmet retention target.

## Consolidation and historical gaps

UndoKit may replace unprotected editing detail with a representation sufficient
to recover retained states and dependencies. Missing detail must remain
explicit: a recoverable Tuesday checkpoint does not imply that Tuesday's
individual edits are still traversable. Consolidation cannot invent continuous
detailed history across a gap.

Protected detailed segments and ordinary Undo/Redo groups retain their promised
Action identities, order, grouping and required data. Retained checkpoint state
and provenance must remain faithful. Accepted Action immutability does not
require retaining every Action forever: authorized pruning can remove
unprotected records, while retained Actions keep their meaning.

## Representation candidates and proof handoff

Evaluate full checkpoint snapshots against snapshots with bounded state
reconstruction. Evaluate dependency-based pruning from retained states,
groups, segments and recovery requirements across branches, including shared
objects. These are candidates to prove within the selected Core Data and
host-owned Retention Store boundaries, not a selected schema or a requirement
to replay historical Commands.

[Issue #46](https://github.com/Folio-Suite/Folio/issues/46) must choose bounded
fixtures and human-approved budgets. Relevant dimensions include group count,
Actions per group, branch and checkpoint count, dependency fanout, retained
bytes, reconstruction distance, traversal/restoration latency, peak memory and
pruning interruption/restart cost. This contract chooses no numeric scale or
performance guarantees.

[Issue #50](https://github.com/Folio-Suite/Folio/issues/50) must prove branching
and retention at that agreed scale, including:

1. restore A after A → B → C, then Undo to C and Redo to restored A;
2. selected-material recovery and editing after Undo with displaced work retained;
3. repeated Undo/Redo within one shared group allowance, including multi-Action groups;
4. faithful checkpoint recovery after preceding detail is consolidated;
5. independent state and history holds, release, overlap and unprotected side branches;
6. protected requirements exceeding a target without expanding ordinary Undo depth;
7. hard-limit refusal without silently releasing protection;
8. permanently ineligible groups with and without host-established independence;
9. explicit historical gaps without changing protected identities or grouping; and
10. shared dependencies and interruption/restart during pruning and object cleanup.

The acceptance, interruption and native-routing proofs remain coordinated with
issues #47–#49. Public interfaces, lifecycle details and numeric budgets remain
with issues #43–#46; the design and proof acceptance gate in #51 precedes Folio
implementation. Compilation, behavioral tests, native observations and human
acceptance remain distinct evidence. Closing #42 resolves this design decision
only.
