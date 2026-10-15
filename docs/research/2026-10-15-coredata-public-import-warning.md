<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Generated Core Data `public import CoreData` warning

## Finding

The warning is reproducible on the pinned Xcode 27.0 (27A266a) / Apple Swift
6.4 toolchain in both UndoKit build routes and configurations. The Core Data
model generator emits a `public import CoreData` in each generated property
extension. UndoKit pairs those extensions with internal `NSManagedObject`
subclass shells. The generated members are written `public`, but their enclosing
classes are internal, so those member declarations do not make Core Data part of
UndoKit's public Swift API. Swift's access-control rules do not allow a member to
be more visible than its type. The compiler therefore reports the explicit
public import as unused for public declarations or inlinable code.

This is an access-level mismatch between Xcode-generated source and the manually
owned internal class shells. It is not a persistence or model-integrity failure.
No setting was found in UndoKit's Package manifest or Xcode project that controls
the access level on the import generated for Category/Extension properties.
The builds and the one-entity reproducer establish the generated output and the
compiler diagnostic. They do not establish why the code generator chooses
`public import` for this arrangement; that generator rationale remains unknown.

## Reproduction

The minimal fixture at
[`scripts/diagnostics/coredata-public-import/`](../../scripts/diagnostics/coredata-public-import/)
contains one entity, one optional string property, and an internal class shell
annotated `@objc(DiagnosticRecord)`. Its model uses
`codeGenerationType="category"`. It emits the same warning in fresh Debug and
Release SwiftPM builds. See the fixture README for commands.

The tested repository source was commit
`3faaf915d0cf43dc626c55524e47b5f6175f4b75` on branch
`codex/31-coredata-imports`. The toolchain reported:

```text
Xcode 27.0
Build version 27A266a
Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
```

All baseline build outputs were isolated under `/private/tmp/undokit-coredata31-*`.
The package runs used fresh per-configuration SwiftPM scratch directories. The
native framework runs used a fresh Derived Data directory and built both
macOS architectures (`arm64` and `x86_64`). Native builds set
`DEBUG_INFORMATION_FORMAT=dwarf` to keep the isolated diagnostic output small;
this does not affect generated Swift imports.

The cold package compiles used these commands; after the diagnostics were
captured, the same Debug and Release scratch roots were rerun with normal
filesystem access to complete the tests:

```sh
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/undokit-coredata31-module-cache \
  swift test --disable-sandbox --package-path . \
  --scratch-path /private/tmp/undokit-coredata31-main-debug

SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/undokit-coredata31-module-cache \
  swift test --disable-sandbox --package-path . \
  --scratch-path /private/tmp/undokit-coredata31-main-release -c release
```

For the successful full test reruns, the same `swift test` commands were run
without `--disable-sandbox` under normal filesystem access. The warning was
already recorded by the initial cold compile; these reruns verified the
existing package tests and persistence checks.

The native framework commands used Xcode's existing SwiftLint package checkout
and resolved package cache, while keeping all build products isolated:

```sh
xcodebuild -project UndoKit.xcodeproj -scheme UndoKit \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath /private/tmp/undokit-coredata31-native \
  -clonedSourcePackagesDirPath /Users/ctwelve/Library/Developer/Xcode/DerivedData/UndoKit/Consumers/Build/Native/SourcePackages \
  -packageCachePath /Users/ctwelve/Library/Caches/org.swift.swiftpm \
  -disableAutomaticPackageResolution DEBUG_INFORMATION_FORMAT=dwarf clean build

xcodebuild -project UndoKit.xcodeproj -scheme UndoKit \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath /private/tmp/undokit-coredata31-native \
  -clonedSourcePackagesDirPath /Users/ctwelve/Library/Developer/Xcode/DerivedData/UndoKit/Consumers/Build/Native/SourcePackages \
  -packageCachePath /Users/ctwelve/Library/Caches/org.swift.swiftpm \
  -disableAutomaticPackageResolution DEBUG_INFORMATION_FORMAT=dwarf build
```

The exact toolchain queries were `xcodebuild -version` and
`xcrun swift --version`. The model compiler resolved as
`/Applications/Xcode.app/Contents/Developer/usr/bin/momc`.

| Route | Configuration | Distinct generated files | Diagnostic events | Build/test outcome |
| --- | --- | ---: | ---: | --- |
| SwiftPM | Debug | 12 | 12 | 125 tests, 1 skipped, 0 failures |
| SwiftPM | Release | 12 | 12 | 114 tests, 1 skipped, 0 failures |
| Xcode framework | Debug | 12 | 24 (12 per architecture) | Build succeeded, universal macOS framework |
| Xcode framework | Release | 12 | 24 (12 per architecture) | Build succeeded, universal macOS framework |

Xcode's text log prints each event twice: once at the source location and once
as the diagnostic marker. The table counts compiler events rather than those
duplicated display lines. Each row came from an uncached compile: new SwiftPM
scratch roots for package builds and a clean isolated Derived Data root for the
native Debug build; the native Release product had its own fresh configuration
directory.

The successful full package runs required normal filesystem access. Initial
restricted executions compiled and showed the same warnings, but test-time
capacity checks and Release `dsymutil` failed because the sandbox could not
inspect/write outside approved paths. A representative store-copy test passed
outside the sandbox, then the full Debug and Release suites passed. These were
execution-context failures, not product failures.

## Cause and evidence boundaries

Verified:

- The generated `*+CoreDataProperties.swift` file contains `public import
  CoreData`, followed by public `@NSManaged` properties and a public fetch
  request method.
- The source shell is `final class History…Record: NSManagedObject` with an
  explicit Objective-C class name, so the generated extension's effective type
  remains internal.
- The single-entity fixture with that same arrangement reproduces the diagnostic
  without UndoKit code or data.
- Swift Evolution proposal SE-0409 describes access-level imports and states
  that `public import` makes a dependency visible to clients. Its Swift 6 rules
  treat imports without an explicit modifier as public by default. The diagnostic
  is specifically about an explicit import access level not being needed by a
  public declaration or inlinable code.
- Apple's Core Data code-generation documentation defines Category/Extension
  as manual class source with an automatically generated properties file, while
  Manual/None makes the developer maintain both. It also states that generated
  build source is regenerated and should not be hand-edited.

Not verified:

- The code-generation template's internal rule for choosing `public import`.
- Whether Apple intends this exact warning for Category/Extension models whose
  class shells are internal, or whether a future Xcode release changes it.
- Every possible undocumented Xcode build setting or compiler flag that could
  affect generated imports.

## Remedy assessment and disposition

No supported generation setting or low-cost source-only correction was
identified that preserves UndoKit's internal managed-object boundary and leaves
the model untouched. Keep the warning as a low-priority toolchain issue and
retain the reproducer.

Making managed-object shells public could make the generated Core Data import
useful to public declarations, but would expose internal persistence types and
their identities to clients. Changing to Class Definition also gives Xcode
ownership of the generated classes, conflicting with the internal shells.
Neither is suitable for UndoKit.

Changing model code generation to Manual/None while checking in property source
could keep the shells internal and preserve the model definition, but it would
replace automatic property generation with hand-maintained generated-like code
for twelve entities. It adds drift and maintenance risk to silence a warning
that does not block builds. Hand-editing build-generated files, broad warning
suppression, and persisted-schema changes remain unsuitable.

Recommended upstream channel: Apple Feedback Assistant, because the behavior
being investigated is in Xcode's Core Data source generator. The Swift compiler
diagnostic documentation is useful supporting context. No report has been
submitted.

### Draft upstream report (not submitted)

**Title:** Core Data Category/Extension emits unused `public import CoreData`
for internal managed-object shells

**Environment:** Xcode 27.0 (27A266a), Apple Swift 6.4, Swift 6 language mode,
macOS 27 SDK.

**Steps:** Build the included minimal Swift package in Debug or Release. Its
model defines one `DiagnosticRecord` entity with Category/Extension code
generation; its source defines an internal `@objc(DiagnosticRecord)` subclass
of `NSManagedObject`.

**Observed:** Xcode-generated `DiagnosticRecord+CoreDataProperties.swift`
contains `public import CoreData`, while Swift emits
`UnusedImportAccess: public import of 'CoreData' was not used in public
declarations or inlinable code`. The build succeeds. UndoKit reproduces the same
diagnostic for 12 generated entity property files; a universal native framework
build emits 12 per architecture.

**Expected / question:** Can the Core Data generator avoid emitting a public
import when its generated public members are attached to a manually maintained
internal class shell, or provide a supported generation choice that respects
that effective visibility? The report includes only a public, one-entity
reproducer.

## Sources

- Apple, [Generating code](https://developer.apple.com/documentation/coredata/generating-code): defines Category/Extension and Manual/None generation behavior.
- Swift Evolution, [SE-0409: Access-level modifiers on import declarations](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md): defines import visibility and Swift 6 defaults.
- Swift compiler, [Unused import access level diagnostic](https://github.com/swiftlang/swift/blob/main/userdocs/diagnostics/unused-import-access.md): defines when public imports are expected to be referenced and documents the warning.
- Swift compiler, [Access Control](https://github.com/swiftlang/swift/blob/main/docs/AccessControl.md): documents declaration visibility and enclosing access scopes.
