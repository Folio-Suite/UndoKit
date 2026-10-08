<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# #48 evidence ledger

## Build identity

The current app bundle was rebuilt by `run.rb` on 2026-09-29 with source base
`8fe3d41fecfe4f6a21ff22ce3eb9d832f2eadb71` and these source hashes.
The initial native UI run preceded that commit and used base
`00852f423740655fc596761e1321fa663e0320cd`:

| File | SHA-256 |
| --- | --- |
| `Package.swift` | `23e829665c0ab438810d1d54a090b1d88854a6cfee909258a0ff70d3b8378fa6` |
| `Sources/NativeProofCore/History.swift` | `b57d7b942be6ecb87d1aaa3eb319bc5c901290641371657d6e35d634716a142b` |
| `Sources/NativeProof/main.swift` | `6a5e7e95f89fb7e4072c622388d85b8456b82ec998ef574f1c211a03b72e9ba0` |
| `Tests/NativeProofCoreTests/HistoryTests.swift` | `0108ac5102974142b49d2611e7194b5c6cac101e0d0efa328da4420d4e7c7989` |
| `run.rb` | `d25cc4e162f152ed98f03c540a52ff9f86a9e03b9178ab89bc9d0267382ce6f6` |

The current executable SHA-256 is
`3b46170fa2a0091e51734c8637d8f9f42f4974ea0ee6c5dedceb8b6fd9b2a5c0`.
The coordinator's native interaction sequence used the previous executable,
whose `main.swift` SHA-256 was
`33522b672bc156e2bedf77b7326deb487296a6ad24e98f65be48812c79d96f1c`.
The later source change blocks semantic Undo/Redo while marked text is active;
that behavior has only compilation evidence.

The initial UI process used `.../T/folio-native-proof-scratch` by explicit
`NATIVE_PROOF_DIR` (A generation `A569F566`). The final process was relaunched
by the app automation into the default `.../T/folio-native-proof` scratch
directory (A generation `69F6BE72`, B generation `29AB2BBB`). Both are
temporary fixtures; their generation IDs and state are kept separate.

## Automated behavior

`ruby UndoKit/prototypes/native/run.rb` completed its final bounded build and
tests in 1.01 seconds, including a 0.20-second incremental SwiftPM Debug build. Four Swift Testing
tests passed in 0.001 seconds (reported test time). The runner's sampled limits
were 180 seconds, 2 GiB memory, 12 GiB owned build/bundle/both-fixture disk and
20 GiB free-space floor. Sampled peaks were 83,804,160 bytes memory and
127,971,328 bytes owned disk. The machine-readable report is at
`.../T/folio-native-proof-build/last-run.json`. These limits covered build
and tests, not the separately driven native app session.

The runner refuses overrides above the accepted 600-second, 2 GiB and 12 GiB
ceilings or below the 20 GiB free-space floor. `NATIVE_PROOF_MEMORY_MIB=2049`
was rejected before spawning a child. Injected watcher failures produced
preserved reports in the same build directory:

| Fault | Preserved report | Child PID | Cleanup check |
| --- | --- | ---: | --- |
| `ps` | `failure-20260929T213159-41634.json` | 41646 | Reaped; PID absent; no cleanup errors |
| `du` | `failure-20260929T213232-41822.json` | 41834 | Reaped; PID absent; no cleanup errors |
| `df` | `failure-20260929T213240-41853.json` | 41865 | Reaped; PID absent; no cleanup errors |

Each failure report records its source hashes, limits, reason, phase, tracked
PIDs, signals and cleanup outcome. The normal final run restored `last-run.json`
without removing these diagnostics. The watcher smoke exercised this small
build/test child tree; it did not launch the AppKit app or prove all detached
descendant timing cases.

## Native interaction record

The coordinator drove the prior bundle through accessibility controls, menus,
keyboard input and text views. Times below are local clock readings from the
app event log. The first run used the explicit `folio-native-proof-scratch`
fixture; after automatic relaunch the app used the default
`folio-native-proof` fixture. No screenshot artifact was retained here.

| Scenario | Native observation |
| --- | --- |
| A/B independent, A clone refresh | A reached `Alpha Beta`, B remained independent. Clone A synchronized after Undo to `Alpha`; detached main A also showed `Alpha`. In the final fixture, B accepted `Other` while A Redo was pending. |
| Edit menu and keyboard Undo/Redo names | In the initial scratch generation `A569F566`, Command-Z changed A `Alpha Beta` → `Alpha`; the menu offered Undo Typing and Redo Typing, and Redo restored `Alpha Beta`. The two-direction status appeared after Undo. |
| Local draft Undo/Redo, including empty priority | Empty local Command-Z was consumed and left document content unchanged. A local draft then Undo and Redo worked independently, including native local Redo. |
| Delayed operation, repeated input and editing barrier | With Delay selected, repeated Command-Z did not enqueue another reversal. Typing `BLOCK` or `NO` into A during pending did not insert text. A main showed read-only/pending with no directions, and the menu command was disabled. |
| Focus switch and detachment while pending | Delayed Redo started from A clone, then Show B and typing `Other` succeeded. At 16:06:54 A completed to `One Two` while B retained focus. Delayed Undo started from A clone at 16:07:13; after detachment the main A view stayed pending until 16:07:23 and then showed `One`. |
| Rejection and unresolved outcome | Rejected Redo at version 10 kept `One`, kept the document clean and removed ordinary Redo availability. Unresolved Undo at version 12 suspended the scope and made it read-only; Resolve advanced to version 13 using simulated no-effect host authority. |
| Unknown registration pause and reconciliation | Unknown `NSDocument.undoManager` registration at version 14 paused the bridge; reconciliation and reattachment reached version 15. `NSDocument edited=true` while proof accepted-change balance stayed zero, so the registration itself was a native dirty signal and was preserved. Automatic discovery of third-party registrations was not tested. |
| Relaunch with both directions, no content replay or dirtying | The default fixture reopened A at generation `69F6BE72`, version 4, content `One`, both Undo and Redo available, `NSDocument edited=false`, proof balance 0. Cloning this clean A at 16:06:16 kept `edited=false` and balance 0. |
| NSDocument dirty state and native notifications | The run observed document edited state as above. It did not establish native `NSUndoManager` Undo/Redo notifications aligned to asynchronous semantic completion; see open gap. |
| Marked composition and localized names | Unrun. Final source blocks semantic reversal while marked text is active. Names remain hardcoded English. |

The known mechanism gaps in [results.md](results.md) remain open even if the
visible routing sequence succeeds.
