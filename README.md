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

The framework remains a Swift scaffold. The template tests
do not establish durable-history behavior. The accepted
[durable-acceptance contract](docs/durable-acceptance-contract.md) now defines
the host/framework transaction and recovery boundary; its public API, storage
model and durable runtime remain future work. Disposable proofs are listed below.

The accepted [history-retention contract](docs/history-retention-contract.md)
defines restoration, shared Undo/Redo depth, checkpoints, separate state and
history holds, and safe pruning under host-selected policy. Its representation
candidates and scale scenarios are being evaluated in disposable proofs.

The accepted [typed-interface contract](docs/typed-interface-contract.md)
defines thin host adapters, opaque versioned payloads, JSON and XML/binary
property-list conveniences, asynchronous ordered submission and bounded reads.
Its isolated Swift proof establishes adapter and codec feasibility, including
fresh-process decoding; it does not implement the production history engine.

The accepted [native-routing contract](docs/native-routing-contract.md) defines
the reusable bridge, pending editing barriers, local text routing, coherent
availability and host presentation obligations. The #48 harness has native
observations and documented mechanism gaps; no production bridge is implemented.

The accepted [store-lifecycle contract](docs/store-lifecycle-contract.md) defines
host-registered document stores, an Application Support default for app-owned
history, safe opening/closing, copying, migration and capacity handling. Measured
limits require disposable storage and scale evidence in #47–#50.

The accepted [measurement plan](docs/acceptance-measurement-plan.md) specifies
mandatory workloads through 100,000 retained groups, optional multi-GiB payload
experiments, runner safeguards and evidence for all four proofs. Timing targets
are advisory; candidate production limits require measurement and review.

## Disposable proofs

These hosts and stores are isolated from the framework target. Their reports
separate observed behavior, simplified fixtures and unmet requirements. Passing
prototype tests does not establish production support or close the proof tickets;
maintainer acceptance and the #51 readiness decision remain outstanding.

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
The accepted next implementation is Swift, serving Folio first and KitchenMemory second while keeping domain-independent interfaces. External Objective-C/XCFramework distribution is deferred until after Folio Suite 1.0. Historical interoperability research remains preserved.

`Project.xcconfig` provides standalone version defaults and optionally inherits
the enclosing Suite's version configuration. The shared scheme can archive the
framework. A separately versioned XCFramework release policy remains to be
settled before publishing a usable external history API.

The original source license and authorship are retained. New integration files
carry the Folio Project's MIT SPDX notices.
