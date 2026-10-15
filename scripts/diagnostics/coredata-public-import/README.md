<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Core Data generated public-import reproducer

This fixture isolates the warning from UndoKit without carrying its model or
consumer data. It has one Core Data entity with `Category/Extension` code
generation and one internal `NSManagedObject` shell with the matching Objective-C
runtime name.

On Xcode 27.0 (27A266a), Apple Swift 6.4, build each configuration into a new
scratch directory so SwiftPM cannot reuse a prior generated source or object:

```sh
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/undokit-coredata31-modules \
  swift build --disable-sandbox \
  --package-path scripts/diagnostics/coredata-public-import \
  --scratch-path /private/tmp/undokit-coredata31-repro-debug

SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/undokit-coredata31-modules \
  swift build --disable-sandbox -c release \
  --package-path scripts/diagnostics/coredata-public-import \
  --scratch-path /private/tmp/undokit-coredata31-repro-release
```

In this restricted execution environment, `--disable-sandbox` and the module
cache override are needed because SwiftPM's subprocess sandbox and default user
caches are outside the writable workspace. A normal local macOS checkout can omit
those environment-specific options. The generated source is under
`<scratch>/out/Intermediates.noindex/CoreDataPublicImportReproducer.build/<configuration>/CoreDataPublicImportReproducer-t.build/DerivedSources/CoreDataGenerated/Diagnostic/`.

Each fresh build emits one `UnusedImportAccess` warning at the generated
`public import CoreData` line and completes successfully. The warning text is
printed both beside the source line and as its diagnostic marker; count the
source-location entry as one diagnostic.
