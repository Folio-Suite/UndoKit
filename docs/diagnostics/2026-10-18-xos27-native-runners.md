<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# xOS 27 native runner investigation

Follow-up for [#68](https://github.com/Folio-Suite/UndoKit/issues/68), performed
18 October 2026. **Two distinct failures were established:** a standalone
SwiftUI simulator compositor abort, and a UIKit check reading a correctly closed
host lease. The UIKit check-order fix passes the real sequence. No workaround
for the SwiftUI compositor abort is established, and UndoKit core is unchanged.

The published 0.2.0 beta and its explicit first-beta-only 26.5 substitution remain
historical records. The results here do not qualify that immutable candidate
retroactively or establish a SwiftUI iPadOS 27 pass.

## Exact standalone reproduction

Host: macOS 27.0.1 (26A434), Apple Silicon, 18 GiB RAM. Controller toolchain:
Xcode 27.1 (27A9275). No other simulator was booted during either standalone
replay. This was ordinary desktop load, not an exclusive scale/performance run;
no continuous host-pressure telemetry was captured for this repetition. The
[earlier investigation](2026-10-12-ipados27-simulator.md) retains separate
cold/fresh-runtime and reduced-load controls.

The original signed arm64 simulator binary was used unchanged from
`build/Diagnostics/Apple-iPadOS27-Metal-Repro-2026-10-12.zip` (SHA-256
`6c66b42a2a141322e2624cbd5c24e16154b7ffbbfcaf788b86ae1a4990aee9ff`).
Its producer was Xcode 27.0 (27A266a). It is a standalone Xcode-template SwiftUI
app with `TextEditor`, `FocusState`, `WindowGroup` and `openWindow`; it does not
link UndoKit. Extract the archive into a new diagnostics folder and run:

```sh
python3 reproduce.py --device AA2181C3-49FC-4F45-9734-895787494D56 --use-prebuilt
python3 reproduce.py --device 605F3099-780E-4052-A8D7-28129CBCAA9D --use-prebuilt
```

The existing replay focuses an editor, opens a peer, externally launches Settings,
then relaunches the same app. It requires actual scene events and watches the
selected simulator's `backboardd` identity and targeted Metal assertions. It
retains an inconclusive or failed verdict rather than inferring success from a
launch or timeout.

| Identical binary | Result | Retained run |
| --- | --- | --- |
| iPad Pro 11-inch (M5), iPadOS 27.0 (24A434), `AA2181C3-49FC-4F45-9734-895787494D56` | **RED exact pixelFormat0** | `PlatformReplay/20261018T194707Z` |
| iPad Air 13-inch (M4), iPadOS 26.5 (23F77), `605F3099-780E-4052-A8D7-28129CBCAA9D` | Full scenario completed, compositor PID stable | `PlatformReplay/20261018T194821Z` |

The new 27.0 abort occurred at 14:47:49 CDT / 19:47:49 UTC. Incident
**`7EB49C21-6BB4-451B-8504-0D0917B689ED`**, `backboardd` PID **3949**, parent
simulator launchd PID **3924**, `SIGABRT`. Targeted logs contain the exact
`MTLTextureDescriptor has invalid pixelFormat (0)` assertion; the crash frames
include `validateWithDevice:`, `newTextureWithDescriptor:` and
`CA::OGL::MetalContext::create_surface_with_properties`. The app scenario's
failed return is a consequence of a system compositor failure, rather than a
runner timeout alone. Unlike the earlier first-beta incident, this new incident
retains the exact pixel-format assertion.

The installed iOS 27.1 runtime (24A94425) refused creation of this iPad profile
with “Incompatible device.” No 27.1 iPad result is claimed. These two runs also
use different iPad profiles; same-profile and memory controls belong to the
separately retained earlier investigation, not to this new comparison.

## Plain AppKit comparison

A new standalone Cocoa app has two ordinary `NSWindow`/`NSTextView` editors,
standard menu actions, and public window/application notification logging.
There is no UndoKit, SwiftUI, host storage or custom rendering. Run:

```sh
ruby scripts/run-appkit-window-probe.rb
```

The CLI builds under the locked shared cache, signs and launches the app, and
prints a unique evidence directory. Use Window > Native Window Probe 2 (Command-2),
bring System Settings forward, return and select Probe 1 (Command-1); then quit
with Command-Q. `Fixture/Events.json` records ordered events, text, selection,
focus and application-active state. Compilation/launch alone is not a pass.
The app refuses to overwrite an existing evidence directory.

On the same macOS 27.0.1 host, the maintainer reports at least three manual
cycles. Retained journal `AppKitWindowProbe/20261018T195715Z-3c7565` contains
repeated peer-editor round trips, unchanged fictional text, restored editor focus
and normal `graceful-termination`. It records one additional application
inactive/active pair beyond the initial remote setup. Do not count every menu
selection as a separate application background/foreground transition or claim
three independently journaled app-deactivation pairs. Earlier remote clicks
changed controls without corresponding real deactivation; those clicks were
not accepted as Settings-transition proof.

**Bounded inability to reproduce:** this AppKit sequence did not fail. It neither
reproduces the remembered older AppKit failure nor disproves it; its original
invocation and precise trigger have not been recovered. This comparison is not
a simulator rendering workaround or a blanket macOS 27 qualification.

## UIKit: a separate closed-lease readback race

The installed UIKit public CLI on the same iPadOS 27 device initially failed at
`delayed acceptance` with `HistoryFailure(.missingHistory, stage: .admission)`.
Evidence: `UIKitNotes/20261018T195651Z-daa0b5`.

The check admits a delayed first-scene operation, activates an independent peer,
then releases the first outcome. On this run the first scene entered background;
its closure correctly waited for the admitted delivery, then released the host
lease. The check immediately read that closed lease before asking the external
runner to reactivate the first scene. Its event journal shows completed
background closure, not a compositor abort or loss of an accepted effect.

The fix preserves the existing peer-focus assertion, external reactivation,
ready-presentation guard and exact note assertion. It moves the authoritative
readback **after** reactivation has reopened the owner. No timeout, receipt guard,
closure safeguard or framework code changes. The real failing CLI invocation
was the red observation; the same invocation passed after the check-order change.

```sh
ruby scripts/run-durable-notes-uikit.rb --device AA2181C3-49FC-4F45-9734-895787494D56
ruby scripts/run-durable-notes-uikit.rb --device AA2181C3-49FC-4F45-9734-895787494D56 --configuration Release
ruby scripts/run-durable-notes-uikit.rb --device 605F3099-780E-4052-A8D7-28129CBCAA9D
ruby scripts/run-durable-notes-uikit.rb --device 605F3099-780E-4052-A8D7-28129CBCAA9D --configuration Release
```

| Runtime | Debug | Release |
| --- | --- | --- |
| iPadOS 27.0 | `20261018T195859Z-5a448a` passed | `20261018T200030Z-fdf7e1` passed |
| iPadOS 26.5 | `20261018T200156Z-6a45d7` passed | `20261018T200320Z-4c5f6e` passed |

All four completed the installed UIKit check, including actual independent
scenes, Settings background/foreground, authoritative receipt readback and final
closure. The checks ran sequentially with only the selected simulator booted.
Their setup records bind the exact uncommitted check-file hash to source
`8d3ab774379413e9f330ce198aa27cb91eb4b74b`; these are follow-up source builds,
not published-beta artifact observations. UIKit's successful path does not
establish that SwiftUI avoids the compositor defect.

## Causal assessment and retry conditions

Verified: the exact compositor abort reproduces without UndoKit; the retained
binary passes the older runtime; plain AppKit does not reproduce it in the
bounded comparison; UIKit's separate lease-order failure is fixed and passes
both configurations on both selected runtimes. This rules out UndoKit as a
necessary dependency of the standalone compositor failure. It does not locate
Apple's internal defect or show that every xOS 27 failure shares one cause.

No arbitrary delay, weakened guard, swallowed failure, or forced scene-state
mutation is offered as a compositor workaround. Continue using the documented
26.5 SwiftUI iPad substitution only within its approved first-beta scope. Retry
the unchanged standalone reproduction when a compatible new iPad runtime/toolchain
is available. Require a stable compositor plus repeated complete focus/peer/
Settings returns before retrying the full SwiftUI host, and retain its durable
state and closure assertions. For the remembered AppKit issue, obtain the exact
old runner/transition before treating it as reproduced.

Reference existing Apple feedback **FB25165352**, identified by the maintainer
as the macOS 27 tooling/platform report. No duplicate Apple report was filed.

## Evidence retention

Large evidence root:
`~/Library/Developer/Xcode/DerivedData/UndoKit/Evidence/PostBeta/2026-10-18/`.
It retains `PlatformReplay`, `AppKitWindowProbe`, each `UIKitNotes` result and
`Manifest.json`. The original reproduction archive remains unchanged at its
repository-local diagnostic path. The
[separate actual IME/expiry observations](2026-10-18-real-native-observations.md)
retain their own exact source-built apps and limitations.
