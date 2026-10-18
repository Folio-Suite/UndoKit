# Installing UndoKit

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Select one dynamic runtime and resource owner per process.

## Add the source package in Xcode

For a first app, choose **File > Add Package Dependencies…**, enter
`https://github.com/Folio-Suite/UndoKit`, and add the dynamic **UndoKit** product to
your app target. Select the source revision you intend to use and commit the
resolved package record. For a published beta, select its immutable release
tag; for an unqualified candidate, select its exact source commit.

Add `import UndoKit` to your Swift sources. Xcode builds the package and its
resource bundle; keep the matching compiled model and privacy resources when
embedding the app. Continue with <doc:FirstUndoGroup> to open a document session.

> Tip: To follow the guides with their app-owned `NotesDocumentLease` and
> `NoteChange` types, open the repository's Durable Notes examples. Those types
> belong to its separate `DurableNotesCore` product; adding UndoKit alone does
> not install them into your app.

## Other supply routes

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

The intended beta matrix is macOS 14 and iOS/iPadOS 17, with producer and initial
consumer Xcode 27.1 build 27A9275 / Apple Swift 6.4, Swift 6 language mode and complete
concurrency checking. No direct Objective-C or other Apple-platform contract is
added. Older/newer compilers require explicit qualification.

Build and simulator evidence is source/artifact-bound and does not imply
floor-OS behavior, physical hardware, binary-distribution or release acceptance.
Clean builds covering declared architectures satisfy CPU coverage without
dedicated Intel execution; actual OS behavior remains a separate requirement. A
development version label is not qualification. Use retained evidence for the exact
selected candidate or published release. Beta updates require rebuilding/relinking
all clients in a process; no drop-in ABI replacement is promised.

## Topics

- <doc:FirstUndoGroup>
- <doc:RecoveryAndStorage>
- <doc:PreviewCompatibilityAndSupport>
