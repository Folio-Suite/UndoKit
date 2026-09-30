<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# UndoKit
A managed persistent undo manager for modern Apple ecosystem apps

## Integration with Folio

UndoKit is an independently buildable framework in the Folio monorepo. Its source,
MIT license, domain vocabulary, research, and unresolved design decisions were
imported from the original repository; see [provenance](UPSTREAM.md) and the
[design index](docs/imported-design/README.md).

The framework now implements the first bounded durable-history operation from
[#53](https://github.com/Folio-Suite/Folio/issues/53): accepted command groups,
reopenable Undo/Redo, checkpoint snapshots and restoration provenance. Core Data
stores protocol structure; host payloads remain opaque. The host owns atomic
semantic effects and durable outcome receipts. See the public DocC catalog and
[Work adapter description](../docs/architecture/work-history-first-operation.md).

Public declarations are grouped in `UndoKit/Interface/`; persistence, transaction
coordination and storage implementations live in `UndoKit/Modules/History/`.
Folio's translation layer lives in `Core/WriteKit/WorkAdapter/`; UndoKit imports
no Folio domain framework. The Core Data model is bundled from
`UndoKit/Resources/`.

The accepted [history-retention contract](docs/history-retention-contract.md)
defines restoration, shared Undo/Redo depth, checkpoints, separate state and
history holds, and safe pruning under host-selected policy. Its representation
candidates and scale scenarios have accepted bounded proof results.

The accepted [typed-interface contract](docs/typed-interface-contract.md)
defines thin host adapters, opaque versioned payloads, JSON and XML/binary
property-list conveniences, asynchronous ordered submission and bounded reads.
Its isolated Swift proof establishes adapter and codec feasibility, including
fresh-process decoding; it does not implement the production history engine.

The accepted [native-routing contract](docs/native-routing-contract.md) defines
the reusable bridge, pending editing barriers, local text routing, coherent
availability and host presentation obligations. The #48 harness has native
observations and documented mechanism gaps; the first production bridge extends native UndoManager routing.

The accepted [store-lifecycle contract](docs/store-lifecycle-contract.md) defines
host-registered document stores, an Application Support default for app-owned
history, safe opening/closing, copying, migration and capacity handling. Measured
limits remain provisional; accepted storage and scale evidence is linked below.

The accepted [measurement plan](docs/acceptance-measurement-plan.md) specifies
mandatory workloads through 100,000 retained groups, optional multi-GiB payload
experiments, runner safeguards and evidence for all four proofs. Timing targets
are advisory; candidate production limits require measurement and review.

## Disposable proofs

These hosts and stores are isolated from the framework target. Their reports
separate observed behavior, simplified fixtures and unmet requirements. Passing
prototype tests does not establish production support. The maintainer accepted
the bounded proofs in #47–#50 with their documented limitations; those tickets
are closed. The accepted [#51 implementation handoff](docs/implementation-handoff.md)
authorizes implementation with verification developed alongside each slice.

| Proof | Evidence |
| --- | --- |
| Durable acceptance and recovery (#47) | [Results](prototypes/recovery/results.md) |
| Native routing (#48) | [Results and mechanism gaps](prototypes/native/results.md), [native observations](prototypes/native/evidence.md) |
| Package lifecycle (#49) | [Results and remaining failure coverage](prototypes/package/results.md) |
| Retention and scale (#50) | [Measured results and limits](prototypes/scale/results.md) |

## Building the framework

Build the shared `UndoKit` scheme in `UndoKit.xcodeproj`, or use the enclosing
`Folio` workspace scheme. The Folio adaptation supplies a public Swift module,
macOS 14 deployment, coordinated Suite release identity, and development
signing. UndoKit has no dependency on FolioKit or any application domain Kit.
The implementation is Swift, serving Folio first and an independent bounded host second while keeping domain-independent interfaces. External Objective-C/XCFramework distribution is deferred until after Folio Suite 1.0. Historical interoperability research remains preserved.

`Project.xcconfig` provides standalone version defaults and optionally inherits
the enclosing Suite's version configuration. The shared scheme can archive the
framework. A separately versioned XCFramework release policy remains to be
settled before publishing a usable external history API.

The original source license and authorship are retained. New integration files
carry the Folio Project's MIT SPDX notices.

## Scope of this implementation

The public typed host adapters support main-actor and actor-owned models, with
host-registered codecs for current writes and earlier payload versions. The
engine opens one scope per physical store. It supports bounded groups and full
checkpoint payloads. Retention holds, pruning, recording controls, explicit
reset, resource cleanup and large paged reconstruction remain follow-up work.
The current format is the first concrete pre-alpha format; no legacy storage
migration is required.

Run the independent tests with `swift test --package-path UndoKit`, or use the
signed Xcode UndoKit scheme. Work integration tests use Core; native document
integration tests use Write. Historical prototype results below are separate
from tests of the implemented engine and do not imply release readiness.
