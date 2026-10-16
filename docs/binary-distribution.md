<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Binary framework assembly

The release producer uses Xcode 27.0 (27A266a) and Apple Swift 6.4. The
assembly command archives the dynamic framework in Release configuration for
macOS 14 (arm64 and x86_64), iOS/iPadOS 17 device (arm64), and iOS/iPadOS 17
simulator (arm64 and x86_64). Device and simulator archives remain separate.

Run from a clean checkout and pass the planned framework version and build
number:

```sh
ruby scripts/assemble-xcframework.rb --version 0.2.0 --build-number 2
```

The command pins those toolchain versions, disables code signing, emits the
Swift distribution interfaces, and retains each `.xcarchive` with its original
dSYM. It assembles the three frameworks and their exact dSYMs into one
`UndoKit.xcframework`. The verifier checks dynamic linkage, architecture and
deployment metadata, every expected Swift interface, the compiled Core Data
model, the privacy manifest, and the binary-to-dSYM UUID match. It also checks
that each XCFramework metadata entry points to its corresponding dSYM directory
inside that variant.

Build intermediates use the shared path
`~/Library/Developer/Xcode/DerivedData/UndoKit/XCFramework/Build`, guarded by
one lock across builds. Set `UNDOKIT_DERIVED_DATA` to select another shared
root. Archives, logs, the assembled bundle, and JSON provenance live in a
unique candidate directory under `XCFramework/Candidates/`. The command
refuses to reuse a candidate identity and records failed runs beside any
partial archives and logs.

After assembly, build and run an independent app against the XCFramework:

```sh
ruby scripts/check-binary-consumer.rb \
  --xcframework "$HOME/Library/Developer/Xcode/DerivedData/UndoKit/XCFramework/Candidates/<candidate>/UndoKit.xcframework"
```

By default, the independent app embeds the selected framework. Pass
`--installation both` to exercise app embedding and host-managed shared macOS
loading, or `--installation shared-macos` for only the latter. The shared case
relocates the same framework beside the consumer evidence and sets
`DYLD_FRAMEWORK_PATH` for launch. It ad-hoc signs the local test framework and
app after relocation so macOS can load them. This checks loader and resource
closure for a host-managed installation; it does not establish publisher
signing, notarization, or an installer contract.

This check copies the bundle into a generated consumer project, removes only
the cached compiled Swift module files from that copy, and asks Xcode to import
the textual distribution interface. An app and a separate domain framework
both import the binary product. The harness compares their public
`HistoryStore` type identities and inspects the loaded-image list to require a
single UndoKit runtime. The installed host opens a history store through
UndoKit's public API, submits a grouped Command, performs Undo and Redo, closes
and reopens the store, and reads the retained group and host receipts. Its
evidence includes the selected runtime binary,
model and privacy-manifest hashes, toolchain, host OS, and the consumer report.
It verifies the bundle against its adjacent producer provenance and records
the producer source separately from the consumer-harness source, so testing an
older candidate from a newer checkout cannot misattribute the binary.
The generated app receives an ad-hoc local signature so macOS can launch it;
the XCFramework itself remains unsigned. Consumer evidence is retained beside
the candidate under `BinaryConsumerRuns/<run-id>/Installations/<platform>/<mode>`. A mixed
source/binary graph is unsupported: before opening host or history stores, the
public type-identity or loaded-image check fails with the observed evidence.
Build logs live under `ConsumerProject-<platform>` and each installation retains
its own `BinaryConsumerEvidence.json`, so a combined platform run preserves all
three installation contexts.

Pass `--platform ios-simulator` to build, install, and launch the independent
host on an available iOS simulator; `--platform both` runs macOS followed by
the simulator. Both options require an explicit `--device UDID` naming an
available iOS simulator. The harness refuses to start a second booted
simulator and shuts down only a device it booted itself. Simulator evidence is
always for the embedded installation; shared-framework loading is a macOS-only
route. For example:

```sh
ruby scripts/check-binary-consumer.rb \
  --xcframework "$HOME/Library/Developer/Xcode/DerivedData/UndoKit/XCFramework/Candidates/<candidate>/UndoKit.xcframework" \
  --platform both --installation both --device YOUR_SIMULATOR_UDID
```

To exercise an actual local macOS archive and export, add `--export-macos`,
`--development-team TEAM_ID` and `--signing-identity IDENTITY` to the embedded
macOS command. Use an installed Apple Development identity (its name or SHA-1).
The runner invokes `xcodebuild archive`, then `xcodebuild -exportArchive` using
the pinned toolchain's `debugging` method, verifies the exported app's development
signature, and launches a copy of that exported app. The same installed resource,
durable receipt, retained-history and runtime-identity checks apply. The archive,
export options, logs and exported app remain in the run's macOS project directory.
This is a development export fixture; it does not establish release host signing,
notarization, Gatekeeper acceptance, or distribution qualification. Export requires
`--platform macos --installation embedded`.

The advanced macOS-only `--probe-mixed-runtime PATH` additionally launches the
installed consumer with an existing source-built `libUndoKit.dylib` supplied via
`DYLD_INSERT_LIBRARIES`. It must reach the explicit type/image identity guard,
exit unsuccessfully, and leave both host state and history stores uncreated.
A dyld refusal or crash does not count as a successful guard check. The evidence
retains a private copy of the alternate runtime, its original path, install name
and SHA-256, the consumer
executable hash, and the exact failure and launch log. The probe does not modify
the selected candidate or inject anything into another process. It can accompany
the development export, but refuses simulator or combined-platform invocations.

Assembly produces an unsigned XCFramework; the consumer command also accepts a
retained signed candidate after full capsule verification. Neither command
publishes or establishes complete floor/current OS behavioral qualification.
Under [the qualification policy](release-qualification.md), architecture builds
replace dedicated Intel execution; specific unresolved physical behaviors and
other release gates retain their own evidence requirements.
