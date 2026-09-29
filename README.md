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
model and runtime proofs remain future work.

The accepted [history-retention contract](docs/history-retention-contract.md)
defines restoration, shared Undo/Redo depth, checkpoints, separate state and
history holds, and safe pruning under host-selected policy. Its representation
candidates and scale scenarios remain future proof work.

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
