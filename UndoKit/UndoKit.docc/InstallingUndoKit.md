# Installing UndoKit

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Select one dynamic runtime and resource owner per process.

## Choose one supply route

Use the source Swift Package, the native Xcode project's framework product, or a
complete direct XCFramework. An app and its domain frameworks must resolve the
same selected UndoKit implementation. Do not link source-built UndoKit alongside
an independently supplied binary, even if version labels agree.

For the source route, resolve the repository package once and link its dynamic
`UndoKit` product from every client. Commit resolved dependencies. Preserve the
built package resource bundle in the installed app. For the native route, link
one producer framework and embed/sign it through the consuming app's workflow.
For binary integration, link the same selected XCFramework from all clients and
let Xcode select the platform/architecture slice.

macOS supports app embedding and deliberately host-managed shared framework
installation. The host owns the shared location, loader paths, access and signing;
UndoKit provides no system installer. iOS/iPadOS uses app embedding. One app-plus-
domain-framework process must load one UndoKit image and the matching model/privacy
resources. A source declaration, version string or successful link is insufficient
proof of installed closure.

## Artifacts and symbols

The complete binary contains macOS arm64/x86_64, device arm64 and separate Simulator
arm64/x86_64 variants. Each framework carries its compiled model and applicable
privacy manifest. Exact-build dSYMs belong inside the XCFramework's per-variant
debug-symbol metadata; consumers do not copy them into production app resources.
A consumer archive must preserve useful matching symbols while the exported
production app contains no dSYM bundles.

Verify the approved publisher/team and certificate fingerprint, the assembled
XCFramework's Apple Distribution signature with secure timestamp, and the final
downloaded ZIP SHA-256 against trusted release provenance. Consuming application
embedding/re-signing remains host-owned. Development or ad-hoc signatures do not
qualify a published binary's authentication.

## Current qualification boundary

The intended preview matrix is macOS 14 and iOS/iPadOS 17, with producer and initial
consumer Xcode 27.0 build 27A266a / Apple Swift 6.4, Swift 6 language mode and complete
concurrency checking. No direct Objective-C or other Apple-platform contract is
added. Older/newer compilers require explicit qualification.

Version 0.2.0 is planned, not published or qualified. Build and simulator evidence
is source/artifact-bound and does not imply floor-OS, Intel execution, physical
hardware, binary-distribution or release acceptance. Use retained evidence for
the exact selected candidate. Preview updates require rebuild/relink of all
clients in a process; no drop-in ABI replacement is promised.

## Topics

- <doc:FirstUndoGroup>
- <doc:RecoveryAndStorage>
- <doc:PreviewCompatibilityAndSupport>
