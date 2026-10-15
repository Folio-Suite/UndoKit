<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Install one UndoKit runtime

Select one supply route for each process. An app and its domain frameworks must
resolve the same UndoKit implementation and resources, even when other libraries
use different distribution routes. Equal version strings alone do not establish
runtime identity. The independent consumers compare Swift type metadata across
the app/domain-framework boundary and count loaded UndoKit images.

The intended preview supports macOS 14 arm64/x86_64, iOS/iPadOS 17 device arm64,
and separate Simulator arm64/x86_64. Use Xcode 27.0 (27A266a)/Apple Swift 6.4,
Swift 6 and complete concurrency checking. These declarations do not qualify an
untested runtime or compiler combination. No qualified `0.2.0` artifact is
published yet; examples below are development integration procedures.

## Source Swift Package

Add `https://github.com/Folio-Suite/UndoKit.git` in Xcode's package dependencies,
choose the intended source revision, and link the dynamic `UndoKit` product.
For reproducible qualification select an exact commit; releases use their exact
version. Commit resolved dependency records. Development consumers may select
updates within the major version, beta within the minor version, and release
engineering pins an exact version; stage transitions are explicit.

An app and its source-built domain framework must refer to the same package
resolution/product. Do not also embed an independently built UndoKit.framework.
SwiftPM supplies `UndoKit_UndoKit.bundle`; preserve the built product's resource
bundle alongside its runtime in the installed app. UndoKit locates its package
resources; clients should not open model-source files from the checkout.

## Native Xcode project

Add `UndoKit.xcodeproj` to the consuming workspace, link its `UndoKit.framework`
product, and make all clients depend on that one producer. For app embedding,
embed and sign that dynamic framework with the consuming app's normal workflow.
The compiled model and privacy manifest belong inside the framework bundle.
Do not add the source package's UndoKit implementation to the same process.

For a host-managed shared Mac installation, the host installs a single versioned
framework and configures app/domain-framework loader paths to that location.
The host owns permissions, signing and updates. UndoKit supplies no installer.
A test fixture's temporary shared directory is a controlled loader experiment,
not a recommendation to weaken system directories or consumer signing policy.

## Direct XCFramework

Use the selected complete `UndoKit.xcframework` from an approved candidate or a
future immutable release ZIP. Verify publisher and checksum before integration.
Keep device and simulator variants separate; let Xcode select the matching
framework slice. Link the same selected XCFramework from the app and its domain
frameworks. For embedded installation, embed and sign the chosen runtime once in
the app. For shared macOS, use the deliberate host-managed installation above.

The release ZIP contains one complete XCFramework with compiled model/privacy
resources and exact-build dSYMs inside its per-variant debug-symbol locations.
Do not copy loose model resources or dSYMs into production app resources. A
consumer archive should retain useful matching debug symbols; exported production
apps must contain no dSYM bundles. Archive/export and symbolication require their
own evidence, not an assumption from framework assembly.

The published assembled XCFramework must have an approved Apple Distribution
signature with a secure timestamp. Verify its publisher/team and fingerprint
against trusted release provenance; then verify the downloaded ZIP's SHA-256.
A locally ad-hoc signed development consumer proves neither publisher trust nor
physical-device distribution. See [the binary contract](binary-distribution.md).

## Run the independent route checks

```sh
scripts/check-consumer.sh --route both --platform both --configuration Debug
scripts/check-consumer.sh --route both --platform both --configuration Release
scripts/check-consumer.sh --route both --platform macos --installation shared-macos --configuration Release
ruby scripts/check-binary-consumer.rb --xcframework /absolute/path/UndoKit.xcframework --platform both
ruby scripts/check-binary-consumer.rb --xcframework /absolute/path/UndoKit.xcframework --platform macos --installation shared-macos
```

The candidate's sibling provenance manifest must identify its exact XCFramework
bytes. Each run records its selected route, platform, architecture, source/artifact
identity and actual outcomes. Consumer evidence verifies a grouped Command,
Undo/Redo, close/reopen and retained History against independently persisted host
state/receipts; it also checks installed model/privacy closure and one runtime.
Consult each command's help for retention and explicit simulator selection. Run
only one simulator at a time; local 26.5 checks distinguish the tracked iPadOS 27
compositor issue from framework behavior.

These checks do not constitute signed downloadable-binary qualification,
floor/current coverage, Intel execution, physical-device acceptance or a release
approval. Inspect the recorded route and environment rather than treating a
passing source consumer as proof of a different artifact.

## Updating or recovering

Rebuild/relink every client in a process against one selected preview version.
Do not replace a loaded dynamic framework as an unqualified ABI-compatible update.
Retain a coherent host-state/history/resource copy before a supported upgrade.
There is no downgrade guarantee or automatic experimental-store migration. A
missing/incompatible existing store is refused and preserved; never handle that
refusal by silently creating empty history. See [compatibility and safe opening](history-compatibility.md).
