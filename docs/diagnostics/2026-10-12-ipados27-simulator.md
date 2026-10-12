<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# iPadOS 27 Simulator compositor blocker — FB25165352

The maintainer submitted Apple Feedback **FB25165352** on 2026-10-12.
Continue local UIKit development on the installed iPadOS 26.5 simulator while
tracking 27 separately. Passing 26.5 does not qualify the deployment floor,
current 27 runtime, Intel execution, or physical devices.

## Evidence

A standalone Xcode-template SwiftUI app using `TextEditor`, `WindowGroup`,
`FocusState` and `openWindow`, without UndoKit or custom UIKit delegates,
reproduces a `backboardd` abort in Metal texture validation:

```
MTLTextureDescriptor has invalid pixelFormat (0).
```

The sequence focuses the editor, opens a peer window, launches Settings, then
returns to the app. One booted simulator ran at a time. The identical signed
binary passed 26.5 and failed 27 on this host. The original comparison included
matching iPad Pro 13-inch (M5) 16GB profiles, as well as a failing 27/12GB profile.
Fresh-device and cold-start observations preceded this comparison.

The reduced-load repeat captured 154 approximately one-second host memory
samples: the pressure counter remained normal, swap usage stayed at 2191.50 MiB,
and the cumulative swap-out counter did not advance. The same 27 failure
recurred. This weakens host memory pressure as the explanation; it does not
exclude sub-second transients or establish Apple's internal cause.

Environment: Xcode 27.0 (27A266a), macOS 27.0.1 (26A434), arm64 host with 18 GiB
RAM; simulator runtimes 26.5 (`23F77`) and 27.0 (`24A434`). The reproducer targets
26.5 and was built once with the 27 SDK. No physical-device result follows.

## Prepared reproduction package

The local attachment is
`build/Diagnostics/Apple-iPadOS27-Metal-Repro-2026-10-12.zip` in the maintainer's
primary checkout. It includes the project, original binary, portable replay,
crash reports, runtime comparison, memory telemetry and draft report. The
packaged replay itself passed on 26.5. These generated files are ignored by Git.
The prepared archive is preserved unchanged:

```
SHA-256 6c66b42a2a141322e2624cbd5c24e16154b7ffbbfcaf788b86ae1a4990aee9ff
```

## UndoKit development baseline

The existing UIKit sample at commit
`f5d5ecc3fad056055966e7f3f8755309f284d910` passed its installed Debug checks on
26.5 after the comparison, with a stable independently observed compositor.
Evidence under the shared build root:
`Evidence/UIKitNotes/20261012T225050Z-15140e`; the compositor observer report was
retained at `/private/tmp/undokit-display-20261012T225049Z` on the test host.

Those checks cover programmatic native control/responder actions, durable
outcomes, scene isolation and actual Settings background/foreground callbacks.
They do not prove human hardware-keyboard/IME behavior or physical data
protection. The sample's lifecycle migration and native typing-group contract
remain separate work; the Apple report is not evidence that those are complete.
