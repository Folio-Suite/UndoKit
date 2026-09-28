<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Imported UndoKit design inventory

Snapshot captured 2026-09-27 from [ctwelve/UndoKit](https://github.com/ctwelve/UndoKit), source commit [`5ca57fd`](https://github.com/ctwelve/UndoKit/commit/5ca57fd54f91ad754ca3d0d8398f67745a7b5be7). The full source bodies, comments (including resolution comments), states, labels, timestamps, original URLs, and native GitHub dependency edges for issues #1–18 are in [issues-2026-09-27.json](issues-2026-09-27.json). This dated provenance snapshot preserves upstream tracker identities; it is not live status or a replacement for those issues.

## Accepted design decisions

- **#2–#4, requirements and research:** consumer requirements, Core Data/native lifecycle constraints, and typed Swift/Objective-C/XCFramework compatibility research are resolved. The findings establish constraints and options; they do not prove implementation or runtime acceptance.
- **#5, ownership and vocabulary:** hosts own semantic meaning, validation, compensation, accepted outcomes, recovery evidence, store location, and history policy. UndoKit owns shared history capabilities, a separate local Core Data history store, native integration, and storage safeguards. Recording does not itself accept domain work.

The destination remains a Core Data-backed, independently consumable XCFramework with typed Swift APIs and independently usable Objective-C APIs. Swift clients retain typed models, including supported Swift Collections values, without manual object-graph decomposition. Folio and KitchenMemory keep distinct history/availability and native-focus policies. Shared generic history UI is deferred. No framework implementation or consumer integration is claimed by this import.

## Open design and proof work

- **Acceptance/recovery gate:** #6 defines durable acceptance, compensation, and interruption recovery; #14 proves recovery and durable invalidation. Verify current status in GitHub before acting. The snapshot records #6 as open and unblocked: its two native blockers, #3 and #5, are closed. It is the next unblocked decision, while its resolution gates downstream work such as #12.
- **Contracts:** #7 branching/checkpoints/retention; #8 typed payloads and interfaces; #9 native routing/restoration; #10 store/package lifecycle and compatibility; #11 XCFramework distribution/adoption.
- **Proof gates:** #12 sets scenarios, scale budgets, and proof criteria; #15–#18 prove native behavior, package failure preservation, cross-language adoption, and branching/retention at scale.
- **Readiness:** #13 is the design-completion gate, depending on its linked work. The map #1 remains open.

GitHub's native blocker relationships are captured as `blockedBy` and `blocking` on each JSON issue record. In particular, #14–#18 are blocked by #12 and block #13. Preserve typed-language interoperability, host-owned semantics and policy, framework capabilities/storage safeguards, and the deferred generic history UI as unsettled work proceeds.
