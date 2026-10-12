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

This check copies the bundle into a generated consumer project, removes only
the cached compiled Swift module files from that copy, and asks Xcode to import
the textual distribution interface. The app links and embeds the binary
framework, opens a history store through UndoKit's public API, submits a
grouped Command, performs Undo and Redo, closes and reopens the store, and
records the host receipts. Its evidence includes the selected runtime binary,
model and privacy-manifest hashes, toolchain, host OS, and the consumer report.
It verifies the bundle against its adjacent producer provenance and records
the producer source separately from the consumer-harness source, so testing an
older candidate from a newer checkout cannot misattribute the binary.
The generated app receives an ad-hoc local signature so macOS can launch it;
the XCFramework itself remains unsigned. Consumer evidence is retained beside
the candidate.

These commands produce and inspect an unsigned candidate. They do not sign,
publish, or qualify OS-floor/current-OS runtime behavior, Intel execution,
physical-device behavior, or shared-framework installation. Those checks
remain separate release gates.
