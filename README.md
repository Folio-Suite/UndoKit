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

## Try it in a small app

[Durable Notes](Examples/DurableNotes/README.md) is a small persisted note editor
with AppKit, UIKit and SwiftUI hosts. From this checkout, launch the Mac app:

```sh
ruby scripts/check-toolchain.rb
ruby scripts/run-durable-notes.rb --launch
```

Choose **Apply grouped example**, Undo, then Redo. Type into the body and try native
Undo/Redo before **Commit typing**. Close and reopen to see the committed note and
history return. The example keeps its Note and authoritative receipts separately
from UndoKit's history database.

| Build with | Guide | Runnable app |
| --- | --- | --- |
| AppKit | [Window and text-view integration](UndoKit/UndoKit.docc/Integration/AppKitIntegration.md) | [Durable Notes](Examples/DurableNotes/README.md) |
| UIKit | [View-controller and scene integration](UndoKit/UndoKit.docc/Integration/UIKitIntegration.md) | [iPhone/iPad app](Examples/DurableNotes/UIKit/README.md) |
| SwiftUI | [Native-backed editors and stable owners](UndoKit/UndoKit.docc/Integration/SwiftUIIntegration.md) | [Mac](Examples/DurableNotes/SwiftUIApp/README.md) · [iPhone/iPad](Examples/DurableNotes/SwiftUI/README.md) |

## Integrate your own document

1. [Add the dynamic UndoKit product](docs/installation.md) to your app. The source
   package is the simplest starting route; native-project and XCFramework routes
   are also supported.
2. [Open one shared session and submit a typed edit](UndoKit/UndoKit.docc/FirstUndoGroup.md).
   Keep `HistorySessions` in your app owner; share a `HistorySession` across windows
   displaying the same document. Give each presentation its own attachment.
3. Bind your native editor and supply the attachment's UndoManager through the
   platform's normal responder route. In SwiftUI, retain the native editor/binding
   outside transient view values and present it with `NativeHistorySwiftUIEditor`.
4. [Connect your model and receipts](UndoKit/UndoKit.docc/Integration/HostingYourModel.md).
   Declare each operation once; call sites submit typed values. Your host commits
   complete group effects and authoritative receipts atomically in its own store.

UndoKit handles ordering, history persistence, native draft settlement and recovery.
Your app retains its model and validates what an edit means. Closing a window
releases its attachment; closing the document explicitly closes its shared session.

Continue with the [DocC catalog](UndoKit/UndoKit.docc/UndoKit.md),
[recovery guide](UndoKit/UndoKit.docc/RecoveryAndStorage.md) and
[history compatibility policy](docs/history-compatibility.md). The source guides
are available now; the versioned hosted documentation site is being prepared.

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

Producer and initial consumer tooling: **Xcode 27.1 (27A9275), Apple Swift 6.4,
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
