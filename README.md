<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# UndoKit
A managed persistent undo manager for modern Apple ecosystem apps

## Ordinary transactions

Pass `HistoryTransactions` to code that submits edits or performs ordinary
Undo/Redo. `HistoryEngine` conforms to this narrow main-actor interface; the
owner keeps the concrete engine for recording, generation changes and closure.

```swift
@MainActor
func apply(_ command: HistoryCommand, using transactions: any HistoryTransactions) async -> HistoryResult {
    return await transactions.submit(command)
}
```

The interface also provides `HistoryTransactions/undo(expectedGeneration:)`,
`HistoryTransactions/redo(expectedGeneration:)` and
`HistoryTransactions/reconcile()`. It exposes one availability callback;
await each operation for its result and use the snapshot for current capability.

The accepted [transaction module ownership decision](docs/adr/0001-transaction-module-ownership.md)
records why ordinary transaction coordination is behind this protocol while
lifecycle controls remain on `HistoryEngine`.

## Retained history

Pass `HistoryReading` to history browsers for bounded metadata, checkpoint
retrieval, reconstruction and coherent native action names. Pass
`HistoryRetentionManaging` to code that creates checkpoints, manages holds and
requests consolidation. `HistoryEngine` implements both capabilities through one
scope-local owner, so an active Recovery Plan protects its required material
automatically. Release or cancel the plan when finished; closing the scope also
ends its protection.

Reading can establish temporary plan protection; it does not imply a read-only
physical store. Hosts interpret the opaque material and reconstruct state.
Physical-store resource cleanup remains on `HistoryStore`, where it covers all
scopes. The [retained-history ownership decision](docs/adr/0002-retained-history-module-ownership.md)
records this split and its lifecycle guarantees.

## Architecture and design records

UndoKit is an independent Swift Package. Its source, MIT license, domain
vocabulary, research, and design decisions were developed in Folio before the
repository split; see [provenance](UPSTREAM.md) and the
[design index](docs/imported-design/README.md).

The implementation supports accepted command groups, reopenable Undo/Redo,
checkpoint snapshots and restoration provenance. Core Data stores protocol
structure; host payloads remain opaque. Hosts own semantic effects and durable
outcome receipts. Historical Folio issue links remain attached to the decisions
they describe; new work belongs in the
[UndoKit issue tracker](https://github.com/Folio-Suite/UndoKit/issues).

Public declarations are grouped in `UndoKit/Interface/`; transaction coordination
lives in `UndoKit/Modules/Transactions/`, retained-history behavior lives in
`UndoKit/Modules/RetainedHistory/`, and persistence and scoped store activity
live in `UndoKit/Modules/Storage/`. Typed host adaptation lives in
`UndoKit/Modules/HostAdaptation/`: it owns codecs, registration validation and
version selection, typed delivery and outcome conversion, and opaque operation
family routing. `Interface/` holds the public contracts and forwarding entry
points; `// MARK:` divisions keep declarations discoverable without duplicating
implementation.
Start with `Interface/HistoryReading.swift` and `HistoryRetentionManaging.swift`
for the retained-history capabilities. `HistoryReconstruction.swift` and
`HistoryRetention.swift` contain their values; `HistorySessionLifecycle.swift`
contains concrete session copy and closure controls. `HistoryRetentionResources.swift`
exposes cross-scope resource maintenance.
UndoKit imports no Folio domain framework. The Core Data model is bundled from
`UndoKit/Resources/`.

The accepted [history-retention contract](docs/history-retention-contract.md)
defines restoration, shared Undo/Redo depth, checkpoints, separate state and
history holds, and safe pruning under host-selected policy. Its representation
candidates and scale scenarios have accepted bounded proof results.

The accepted [typed-interface contract](docs/typed-interface-contract.md)
defines typed host adapters, opaque versioned payloads, codec conveniences,
asynchronous ordered submission and bounded reads. Its isolated Swift proof
establishes adapter and codec feasibility, including fresh-process decoding;
it does not implement the production history engine. The implementation's
module ownership and typed callback context are recorded in
[ADR 0003](docs/adr/0003-host-adaptation-module-ownership.md).

The accepted [native-routing contract](docs/native-routing-contract.md) defines
the reusable bridge, pending editing barriers, local text routing, coherent
availability and host presentation obligations. The #48 harness has native
observations and documented mechanism gaps; the first production bridge extends native UndoManager routing.

The accepted [store-lifecycle contract](docs/store-lifecycle-contract.md) defines
host-registered document stores, an Application Support default for app-owned
history, safe opening/closing, copying, migration and capacity handling. The
physical `HistoryStore` now supports multiple ordered scopes, one writer, read-only
inspection, coordinated whole-store copies and asynchronous closure. Structural
migration and measured production limits remain future work.

The accepted [measurement plan](docs/acceptance-measurement-plan.md) specifies
mandatory workloads through 100,000 retained groups, optional multi-GiB payload
experiments, runner safeguards and evidence for all four proofs. Timing targets
are advisory; candidate production limits require measurement and review.

See [retention implementation and measurements](docs/retention-implementation.md)
for the supported maintenance boundary and guarded production-engine case.

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

## Building the package

The source package and native framework project target macOS 14 or later
(arm64/x86_64) and iOS/iPadOS 17 or later (device arm64, separate simulator
arm64/x86_64). They use Swift 6 with complete concurrency checking. The producer
toolchain is Xcode 27.0 (27A266a), Apple Swift 6.4; verify it with
`ruby scripts/check-toolchain.rb`. Swift Package Manager is authoritative for
unit tests. [ADR 0005](docs/adr/0005-preview-source-and-project-platforms.md)
records the scope; binary distribution and full release qualification remain
later gates.

From the repository root, run `swift test` and `swift test -c release`.
`scripts/check-consumer.sh` runs an independent macOS package consumer. For the
complete source/project check, run each configuration:

```sh
scripts/check-consumer.sh --route both --platform both --configuration Debug
scripts/check-consumer.sh --route both --platform both --configuration Release
```

The shared fixture submits a grouped Command, performs Undo/Redo, closes and
reopens durable history alongside separately persisted host state and receipts.
The native macOS product is built for both architectures; runtime evidence is
reported for the executing architecture. The iOS path runs in an installed
simulator app. Checks inspect the installed compiled model and privacy manifest.
Builds and generated consumers live under the repository's ignored `DerivedData/`.
Use `--keep` to retain evidence there. CI runs both configurations. Debug-only failure
injection tests are excluded from Release; ordinary durability and consumer
checks run in both. These checks do not establish floor-OS, Intel execution,
physical-device, signed distribution or XCFramework qualification.

The bundled privacy manifest declares available-disk-space checking for copy
capacity admission (Apple reason E174.1), and file metadata checks for stable
opening snapshots in app containers or user-authorized documents (C617.1/3B52.1).
UndoKit does not transmit this data;
hosts remain responsible for their own privacy declarations. See Apple's
[required-reason API documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

The guarded production-scale case can be measured with
`scripts/check-undokit-scale.rb [groups]`. It defaults to 10,000 groups and accepts
100–100,000; the runner enforces disk, resource and time bounds and retains its
report and log in a temporary directory. It is not part of routine CI.

The source package begins at `0.1.0` with independent release tags. Consumer
requirements follow the consumer's stage: development allows updates within the
selected major version (including across minor versions during `0.x`); beta
allows updates within the selected minor version; release engineering requires
an exact version. Commit resolved dependency records at every stage. Stage
transitions are deliberate and are not inferred from UndoKit's version number.
API and storage compatibility follow the accepted
[history compatibility policy](docs/history-compatibility.md); a dependency
range alone is not a promise of persisted-format migration.

The original source license and authorship are retained. New integration files
carry the Folio Project's MIT SPDX notices.

## Scope of this implementation

The public typed host adapters support main-actor and actor-owned models, with
host-registered codecs for current writes and earlier payload versions. A physical
store supports independent scopes, bounded groups, full checkpoint payloads,
durable state and detail holds, bounded consolidation, opaque resource references
and serialized host cleanup across scopes. See the DocC retention guide and
[reconstruction](docs/history-reconstruction.md) for bounded historical reads and
presentation metadata. Hosts can turn recording Off for new ordinary edits while
keeping open-session Undo, then turn it On with a coherent baseline. Settled clear
and acknowledged unresolved reset retire a scope generation; clients bind new
commands to the returned generation. The current format is pre-alpha; no legacy
migration is required.

Run package tests from the repository root with `swift test`. Historical
prototype results below are separate from tests of the implemented engine and
do not imply release readiness.
