<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Preview source and project platforms

The accepted resolutions of [#5](https://github.com/Folio-Suite/UndoKit/issues/5)
and [#7](https://github.com/Folio-Suite/UndoKit/issues/7) extend the independent
Swift package and native framework project to macOS 14 (arm64 and x86_64),
iOS/iPadOS 17 (device arm64), and separate simulator arm64/x86_64 products.
This supersedes ADR 0004's macOS-only baseline and iOS deferral. Both routes
carry their compiled Core Data model and privacy manifest and use Swift 6,
complete concurrency checking, and producer Xcode 27.0 (27A266a)/Swift 6.4.

The dynamic product and one-runtime-per-process rule remain: hosts and shared
domain frameworks must use the same UndoKit runtime. Independent consumers
exercise grouped Commands, Undo/Redo, durable receipts and reopen for both
integration routes. Swift Package Manager remains authoritative for unit tests.
Debug and Release checks cover different conditional-code paths.

These source/project checks do not qualify a binary release. The later
XCFramework, signing, installation and deployment-floor/current OS behavioral
gates remain required. [ADR 0007](0007-os-behavioral-qualification.md) supersedes
the original blanket Intel/physical execution requirements with architecture
build acceptance and behavior-driven hardware checks. Unsupported Apple platforms
are outside this contract.
