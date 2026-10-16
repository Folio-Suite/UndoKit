<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# UndoKit

Durable application history for Swift apps on macOS, iPhone and iPad. Hosts keep
native live typing Undo/Redo while explicit editing transactions become persistent
Undo Groups. History survives reopening; the app owns domain meaning and its
primary data.

**Development preview:** `0.2.0` is planned, not released or qualified. The current
source is under API frost, with changes needed for qualification still possible.
Do not treat `main`, a successful build, or a simulator run as a qualified release.

## Start here

1. Choose the [installation route](docs/installation.md): source Swift Package,
   native Xcode project, or a complete dynamic XCFramework.
2. Build [Durable Notes](Examples/DurableNotes/README.md), the small persisted
   example with authoritative host receipts. Native AppKit/UIKit and SwiftUI
   macOS/iPhone/iPad hosts share its domain.
3. Follow the [first Undo Group and recovery walkthrough](docs/getting-started.md).
4. Browse the in-repository [DocC catalog](UndoKit/UndoKit.docc/UndoKit.md) and
   [history compatibility policy](docs/history-compatibility.md).

The independent versioned documentation site is being prepared. No hosted
`0.2.0` release documentation or latest-release pointer is available yet.

## Ownership

| UndoKit owns | The host owns |
| --- | --- |
| Command ordering, durable preparation/finalization and recovery evidence | Domain meaning, validation, no-op filtering and authoritative atomic effects |
| Undo Group relationships, retained History and bounded reconstruction material | Durable outcome receipts, codecs and required host resources |
| Native binding admission, draft journaling and editing settlement | Stable document/session ownership, presentation and retention policy |

UndoKit is **not a primary datastore or backup system**. It does not infer success
from a request, choose how to compensate domain effects, or recover deleted host
content from opaque payloads without the host's codecs and resources.

## Platform and tooling contract

| Target | Declared floor | Architectures |
| --- | --- | --- |
| macOS | 14 | arm64, x86_64 |
| iOS/iPadOS device | 17 | arm64 |
| iOS/iPadOS Simulator | 17 | arm64, x86_64; separate device variant |

Producer and initial consumer tooling: **Xcode 27.0 (27A266a), Apple Swift 6.4,
Swift 6 mode and complete concurrency checking**. These are the intended preview
requirements. Exact tested environments and unqualified cases belong to each
candidate's evidence; the matrix alone is not runtime qualification. Direct
Objective-C and other Apple platforms are outside this contract.

Preview updates require rebuilding/relinking every client in a process against
one selected UndoKit version and supply route. No drop-in ABI replacement or
blanket compiler compatibility is promised. See [binary integration](docs/binary-distribution.md)
for resources, signing and bundled exact-build dSYMs.

## Build and verify

```sh
ruby scripts/check-toolchain.rb
scripts/test-package.sh
scripts/test-package.sh -c release
scripts/check-consumer.sh --route both --platform both --configuration Debug
scripts/check-consumer.sh --route both --platform both --configuration Release
```

Use Xcode's configured default DerivedData. Repository runners reuse locked build
databases under `~/Library/Developer/Xcode/DerivedData/UndoKit`; see
[contributor prerequisites and scoped checks](CONTRIBUTING.md). Build settings and
universal compilation do not establish OS behavioral passes. The
[qualification policy](docs/release-qualification.md) accepts declared-architecture
builds without dedicated Intel execution while retaining floor/current OS tests
and physical checks for specific unresolved behaviors. The
[guarded production scale protocol](docs/production-scale.md) is opt-in; its
reports distinguish full workloads, simulator smoke and physical measurements.

## Compatibility, support and provenance

Before the first qualified preview there is no promised migration from `0.1.0`
or experimental stores. Unsupported stores are preserved and refused. The first
qualified preview will establish the supported persisted-history baseline;
subsequent continuity promises and explicit migration requirements are defined
in the [compatibility policy](docs/history-compatibility.md).

Use [GitHub Issues](https://github.com/Folio-Suite/UndoKit/issues) with a small
sanitized reproduction and version/source, route, architecture, OS and tooling.
Never post real host databases, user content or raw payloads. Follow
[SECURITY.md](SECURITY.md) for private vulnerability reporting. Support for the
latest published preview is best effort, with no response-time guarantee or
routine backports; older previews receive upgrade guidance.

UndoKit originated in Folio and is maintained independently. See
[provenance](UPSTREAM.md), the [domain glossary](CONTEXT.md),
[accepted architecture decisions](docs/adr/0004-independent-source-package.md),
[historical design evidence](docs/imported-design/README.md) and the
[MIT license](LICENSE). Historical proofs do not qualify the production release.
