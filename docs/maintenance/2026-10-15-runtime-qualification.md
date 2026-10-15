<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Production runtime evidence — 2026-10-15

This records partial evidence for [#26](https://github.com/Folio-Suite/UndoKit/issues/26).
The actual production Swift package tests passed on the available iPadOS 26.5
simulator in both configurations. This does not complete the required
floor/current matrix or qualify a preview candidate.

## Source and environment

Tested source: `3faaf915d0cf43dc626c55524e47b5f6175f4b75`.
The [source and artifact manifest](2026-10-15-ios-runtime-evidence.json)
contains SHA-256 hashes of all 103 package inputs: `Package.swift`, `UndoKit/`,
`UndoKitTests/` including fixtures, and `scripts/scale/` including its workload
dependency. Before recording the results, every input in the isolated package
projection was compared byte-for-byte with the checkout and `git show` at that
commit. No package, framework, test or fixture source was changed for this run.
The production `UndoKit/` Git tree is
`3aded59eaa556e0639662c41408353c873730302`.

Producer: Xcode 27.0 (`27A266a`), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), macOS 27.0.1 (`26A434`), arm64.
Tests used SDK iPhoneSimulator 27.0 (`24A430`) and an arm64 tablet simulator
running iPadOS 26.5 (`23F77`). The runtime version, rather than the SDK version,
is the execution evidence. Exact simulator identity and unsanitized output are
retained privately with the result bundles.

## Results

| Runtime | Configuration | Passed | Skipped | Failed | Result |
| --- | --- | ---: | ---: | ---: | --- |
| iPadOS simulator 26.5 (23F77), arm64 | Debug | 124 | 1 | 0 | Passed; 125 discovered |
| iPadOS simulator 26.5 (23F77), arm64 | Release | 113 | 1 | 0 | Passed; 114 discovered |

The skip is the existing opt-in `HistoryScaleTests` smoke case. The 10,000-step
scale workload was not run. Debug includes 11 cases compiled out of Release;
ordinary behavior, baseline, opening, retention, reconstruction and recovery
cases run in both. These are the package's existing tests, including the
`ScaleWorkload` dependency and bundled test fixtures, without a duplicate test
project or selected replacement suite.

The passing results include grouped transaction atomicity and Undo/Redo,
retained reconstruction and retention, production persistence-boundary failure
and reconciliation, and the paired baseline recipe with codecs, host state and
resources. `HistoryOpeningCompatibilityTests` verifies corrupt SQLite,
unregistered compatible models, unsupported newer models and unrelated models
are refused without changing the original artifacts. The baseline test rebuilds
its fixture on the tested runtime; it does not claim a 0.1.0 upgrade path or a
future format migration.

The first Release attempt stopped during compilation: Xcode's default Release
configuration built UndoKit without `-enable-testing`, while existing tests use
`@testable import UndoKit`. The successful Release command adds
`ENABLE_TESTABILITY=YES`, as needed for those existing test imports. Its compiler
commands retain `-O`, whole-module optimization, and no `DEBUG` condition. This
is a test build and does not establish distribution artifact identity. The
failed setup log and result bundle are retained alongside the successful run.

## Reproduce the package workspace

SwiftPM is the authoritative source/test definition. Opening `Package.swift`
in Xcode creates its supported package workspace and generated schemes, as
Apple describes in [Creating a standalone Swift package with Xcode](https://developer.apple.com/documentation/xcode/creating-a-standalone-swift-package-with-xcode).
Running `xcodebuild` directly in this repository selects the optional native
project; running it in a package-only directory before Xcode has opened the
package does not create a workspace in this toolchain.

From the repository, create an isolated projection of the exact committed
package graph. These commands intentionally use the recorded source revision;
change the revision explicitly when collecting new evidence.

```sh
runtime_source=3faaf915d0cf43dc626c55524e47b5f6175f4b75
runtime_package=$(mktemp -d "${TMPDIR:-/tmp}/undokit-runtime.XXXXXX")
git archive "$runtime_source" Package.swift UndoKit UndoKitTests scripts/scale \
  | tar -x -C "$runtime_package"
xed "$runtime_package/Package.swift"
```

Wait for Xcode to open the package and resolve its graph. Then inspect the
workspace Xcode generated; the observed scheme was `UndoKit-Package`.
Do not generate a second set of production/test targets by hand.

```sh
xcodebuild -workspace "$runtime_package/.swiftpm/xcode/package.xcworkspace" \
  -list -json
```

Select an available simulator explicitly with `xcrun simctl list devices
available`. Set `runtime_device` to its UDID. With exclusive access to the
selected simulator and build directory, run both configurations:

```sh
runtime_build="${UNDOKIT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/UndoKit}/RuntimeQualification"
runtime_output=$(mktemp -d "${TMPDIR:-/tmp}/undokit-runtime-results.XXXXXX")
runtime_status=0
for runtime_configuration in Debug Release; do
  xcodebuild \
    -workspace "$runtime_package/.swiftpm/xcode/package.xcworkspace" \
    -scheme UndoKit-Package -configuration "$runtime_configuration" \
    -destination "platform=iOS Simulator,id=$runtime_device" \
    -derivedDataPath "$runtime_build" \
    -resultBundlePath "$runtime_output/$runtime_configuration.xcresult" \
    ENABLE_TESTABILITY=YES test \
    > "$runtime_output/$runtime_configuration.log" 2>&1 \
    || { runtime_status=$?; break; }
done
test "$runtime_status" -eq 0
```

The recorded Debug run used Xcode's default enabled testability; Release used
the explicit setting above. Preserve exit status, full output and `.xcresult`,
and extract each summary with `xcrun xcresulttool get test-results summary
--path <bundle> --format json`. A failed or missing mandatory case blocks
qualification; investigate it before claiming another successful matrix row.

## Retained evidence and limits

Private evidence is retained under
`~/Library/Developer/Xcode/DerivedData/UndoKit/RuntimeQualification/Evidence/2026-10-15-ios-26.5/`:

- `undokit-26-ios-debug.log`, `.xcresult`, and `-summary.json`;
- `undokit-26-ios-release-testable.log`, `.xcresult`, and `-summary.json`;
- the failed `undokit-26-ios-release.log` and `.xcresult`;
- `package-projection/`, simulator inventory, result-file hash manifests, and
  `Products/Debug/` and `Products/Release/` test bundles and dynamic frameworks.

The public manifest identifies the raw logs and result-file manifests by hash,
and hashes the matching runtime/test binaries, compiled model, privacy manifest
and copied baseline fixtures. Copies of the build products are retained because
subsequent runs can overwrite the shared build directory. Public evidence omits
private simulator UUIDs, names and absolute developer paths.

This available 26.5 simulator row supplements the runtime matrix. It does not
replace the selected current iOS/iPadOS runtime or deployment-floor evidence.
The iPadOS 27 simulator compositor failure remains tracked as `FB25165352`.
macOS 14 and iOS/iPadOS 17 floor execution are missing; Intel execution remains
explicitly deferred by the user. Physical-device qualification is separate
[#27](https://github.com/Folio-Suite/UndoKit/issues/27) work. Abrupt termination,
physical lock/IME behavior, signed installation and binary candidate acceptance
are not established here. Issue #26 remains open until its mandatory runtime
coverage and exclusions are resolved under the accepted contract.
