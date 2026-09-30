<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Accepted implementation handoff

The maintainer accepted the #51 handoff after accepting the bounded proofs
#47–#50. Begin implementation under the existing durable acceptance, retention,
typed interface, native routing and store lifecycle contracts. The proofs
establish sufficient feasibility to proceed; their reports retain the exact
source identities, observations and limitations.

## Production direction

Build one coherent Swift engine with independently usable public interfaces.
The prototypes remain reference fixtures. Carry their scenarios, expected
outcomes and regression tests forward; assess code reuse individually. Their
snapshot stores, pointer-based reversals and separate models are not an adopted
production architecture.

Hosts continue to own semantic meaning, no-op filtering, validation, atomic
compensation, authoritative outcomes, recovery evidence and application policy.
UndoKit owns ordering, opaque durable storage, structural history relationships,
recovery bookkeeping and storage safeguards. No Folio types enter UndoKit.

## Resolve mechanics while implementing

Implement the native bridge alongside tests of its concrete mechanism. No
additional disposable-prototype round blocks implementation. Preserve the
accepted native behavior: host-settled typing groups, marked composition,
coherent availability, completion-aligned notifications and document change
counts, and detection/reconciliation of independent registrations. Establish
these behaviors before adopting the bridge in the application. The proof's idle
timer is not the production typing-group contract.

Retain the initial performance and memory targets as engineering guidance.
The mandatory large datasets established enough feasibility to begin; they did
not calibrate production maxima or incremental-memory usage. Numeric request
limits remain provisional and configurable while the implementation is tested.
The proof's 16 MiB recovery page is an experimental setting, not a selected
production default. Measure real allocations and host responsiveness as the
engine takes shape, without delaying implementation for another scale campaign.

## Grow verification with each slice

Each operation's implementation must include its relevant regression and failure
coverage before application adoption. In particular:

- Transaction coordination: queue ordering, cancellation boundaries, duplicate
  retry, whole-group inverses, receipt authority and failures after acceptance.
- Store lifecycle: real save/rollback failures, competing writable ownership,
  close/reopen interruption, safe capacity admission and preserved originals.
- Native integration: grouping/composition, notification and dirty-state timing,
  independent registrations, localization, pending barriers and focus behavior.
- Retention: interrupted maintenance, resource protection and serialized cleanup,
  bounded material reads, measured memory and host reconstruction latency.

Keep the proof tickets closed. Their gaps become acceptance obligations of the
implementation slices; reopen a design decision when evidence contradicts its
contract. This handoff does not claim that these checks already pass.

## First implementation sequence

[#52](https://github.com/Folio-Suite/Folio/issues/52) establishes incremental Work
persistence while preserving unchanged content/assets and native save semantics.
Its accepted migration prerequisite #40 is closed.

[#53](https://github.com/Folio-Suite/Folio/issues/53) then implements the first
coherent UndoKit/WriteKit operation: reopen a Work with durable Undo, create a
checkpoint and restore while retaining displaced work. It includes interrupted
acceptance, retry, group failure and capacity checks, plus an independent bounded
Swift host representing KitchenMemory policy. Publish narrow successors for
accepted capabilities outside that operation instead of expanding this slice
into the entire engine.

Preserve original design provenance. Objective-C/XCFramework distribution remains
deferred beyond Folio 1.0; this handoff adds no mobile or distribution promise.
