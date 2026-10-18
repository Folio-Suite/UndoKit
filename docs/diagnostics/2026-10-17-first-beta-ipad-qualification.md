<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# First-beta iPad qualification: selected 26.x runtime

On 17 October 2026, the maintainer confirmed that no physical iPad capable of
running 27 was available and directed: “We'll need to be happy with 26.x.”
For the `0.2.0` first beta only, the selected iPadOS 26.5 simulator may supply
the iPad native behavioral qualification in place of the blocked 27 simulator
attempt. The applicable Debug and Release checks passed as recorded below.

This is a release-specific maintainer substitution, not a general change to
[OS behavioral qualification](../release-qualification.md). It does not prove
current iPadOS 27 behavior or physical iPad behavior on either version, change
compatibility promises, or approve publication of an exact release candidate.
Other package, consumer, artifact, signing, documentation and physical-behavior
gates retain their separate evidence and decisions.

## Retained native evidence

The producer is Xcode **27.1 (27A9275)** with Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, embedded Clang `2100.3.34.1`). Source checkpoints:

- **A:** `241d7770a6c8ba7de203bd27c07090eef9d14389`.
- **B:** `bab4d7daf10656d9a02322d079fe574428831a0c`.

The following clean-source installed CLI runs have retained successful reports.
These are selected native sample checks, not a claim that every release gate
ran on each listed runtime. The older checkpoint remains explicitly identified.
Evidence paths below are relative to
`~/Library/Developer/Xcode/DerivedData/UndoKit/Evidence/` on the qualification host.
Each run's `Setup.json` records its source, configuration, simulator, toolchain
and executable/framework SHA-256 identities; successful fixtures retain
`Fixture/Report.json` and authoritative Note/receipt files.

| Host/check | Simulator | Configurations | Source | Retained evidence |
| --- | --- | --- | --- | --- |
| UIKit | Floor iPad 17.5 | Debug, Release | A | `UIKitNotes/20261018T000047Z-5a9eba`, `UIKitNotes/20261018T000105Z-89f9c0` |
| UIKit | Current iPhone 27.0 | Debug, Release | A | `UIKitNotes/20261018T000155Z-fb9c16`, `UIKitNotes/20261018T000259Z-16e427` |
| SwiftUI | Floor iPhone 17.5 | Debug, Release | B | `DurableNotesSwiftUIiOS/20261018T002205Z-ca7210`, `DurableNotesSwiftUIiOS/20261018T002241Z-ad64c3` |

The UTC evidence identifiers cross into 18 October; these observations and the
maintainer's direction occurred on 17 October in the host's local timezone.

## Current iPad 27 attempt remains failed

The SwiftUI Debug run on the iPad Pro 11-inch (M5), simulator
`AA2181C3-49FC-4F45-9734-895787494D56`, used clean checkpoint B. Its retained
record is `DurableNotesSwiftUIiOS/20261018T002326Z-9dbf1a`. Release was not run.
The installed payload is retained there as `Installed.app`; it is not a mutable
shared build-cache reference. Its `Setup.json` records:

```text
executable SHA-256 62c9373ba6d21ba1207160a1b5b7591e19cd143dacc8e3ced63eec6d1e12c217
UndoKit SHA-256    10b9c8afe58ad5fdc23020b45a358002c95ddce65ffafee770c32c1c6f0f4fb9
```

`SimulatorFailure/Summary.json` seals incident
`CF1668A5-AF89-46D4-BE62-8970B639DE4F`: the simulator system compositor process
`backboardd` aborted with `SIGABRT`, with Metal texture-validation frames including
`-[MTLTextureDescriptorInternal validateWithDevice:]` and
`-[MTLSimDevice newTextureWithDescriptor:]`. The retained stage reached Settings
background; `BackgroundClosed.json` records completed closure. The end-to-end
Settings return remained incomplete: neither `ForegroundReady.json` nor
`Report.json` exists. This is not a successful run, an observed framework closure
failure, or a deliberate forced-termination recovery test.

The maintainer identifies **FB25165352** as the existing macOS 27 tooling/platform
feedback. The [earlier simulator investigation](2026-10-12-ipados27-simulator.md)
retains a standalone SwiftUI reproduction without UndoKit. The present host
simulator abort has the same Metal texture-validation failure family and
focus/peer/Settings sequence. Its exact `pixelFormat (0)` assertion text was not
captured; the earlier report's exact assertion must not be attributed to this
incident. Use the existing macOS 27 feedback for this tooling failure; no duplicate iPadOS
report is required for this beta.

## Selected first-beta iPad replacement

The following runs passed on the installed iPadOS 26.5 simulator,
iPad mini (A17 Pro), `762F276E-1859-4024-A76B-803095A8311A`.

| Check | Configuration | Result | Source / retained evidence |
| --- | --- | --- | --- |
| SwiftUI iPad 26.5 | Debug | Passed | B / `DurableNotesSwiftUIiOS/20261018T002903Z-09ff3f` |
| SwiftUI iPad 26.5 | Release | Passed | B / `DurableNotesSwiftUIiOS/20261018T003034Z-763e86` |

Both runs completed the full installed checks, including independent scene edits,
the real Settings round trip, recovery and final presentation/store closure. The
external runner independently read the authoritative note and receipt counts.

The maintainer substitution accepts successful 26.x iPad evidence for this first
beta's selected iPad runtime; it cannot establish a 27 pass. Keep the failed 27
record and this limitation alongside any later 26.5 passes. Revisit the current
27 iPad end-to-end Settings return when Apple supplies a working simulator/tooling
combination or suitable hardware becomes available. Physical keyboard/IME,
physical file protection and OS background-expiry questions are not answered by
these simulator runs.
