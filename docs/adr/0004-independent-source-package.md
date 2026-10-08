<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Independent source package

Accepted on 2026-10-08.

UndoKit is developed and consumed as an independent Swift Package. Swift
Package Manager defines its supported build and test workflow. The Xcode
project remains an optional developer harness with its own standalone defaults;
it does not inherit Folio Suite configuration.

- **platform baseline:** macOS 14 or later and Swift 6.
- **source distribution:** the package bundles its Core Data model as a
  resource; an independent consumer check opens a store through the public API.
- **release scope:** the initial package version is `0.1.0`. iOS qualification
  and XCFramework distribution are deferred; no binary product is promised.
- **consumer dependency policy:** development allows updates within the selected
  major version, including across minor versions during `0.x`; beta allows updates
  within the selected minor version; release engineering uses an exact version.
  Consumers commit resolved dependency records. These are deliberate consumer
  stage transitions, not rules inferred from the framework version number.
- **linkage:** the package exports one dynamic library product, preventing
  duplicate runtime identities when an application and its domain frameworks
  both import UndoKit. The Core Data resource bundle must accompany that runtime.
- **CI:** macOS with Xcode 27 runs `swift test` and an independent source
  consumer smoke check.

This decision establishes package and compatibility boundaries; it does not
qualify persistence-format migration or binary distribution.
