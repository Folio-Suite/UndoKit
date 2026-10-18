<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Actual IME composition and OS background expiry

Tickets: [#69](https://github.com/Folio-Suite/UndoKit/issues/69) and
[#70](https://github.com/Folio-Suite/UndoKit/issues/70).

Both previously deferred observations were performed on 2026-10-18, against
source-built **Debug** samples at released source
`8d3ab774379413e9f330ce198aa27cb91eb4b74b`. The setup records report a clean
checkout. Xcode 27.1 (27A9275), Swift 6.4, host macOS 27.0.1 (26A434), arm64,
18 GiB RAM. These bounded follow-ups do not modify the released 0.2.0 assets,
manifest, or historical first-beta qualification/deferment.

[Machine-readable setup and authoritative readbacks](evidence/2026-10-18-native-observations.json)
retain original identities, receipt members, acceptance/rejection, application
counts and hashes of the raw JSON files. Larger screenshots, the installed
apps and raw fixture files are retained under the shared DerivedData evidence
root; see the retained evidence index below.

## Real Japanese composition on AppKit

Build: `ruby scripts/run-durable-notes.rb --configuration Debug`.
Launch the installed executable with `UNDOKIT_NOTES_ROOT` pointing to a new
fictional-data fixture. The application opens independent documents A and B.

The maintainer authorized temporarily adding **Japanese – Romaji**. Live
Conversion was enabled by the OS default. Actual key events went through that
input method; neither `setMarkedText` nor insertion of precomposed Japanese
text was used. The baseline English values used ordinary paste.

1. In B, paste title `IME baseline`, body `Before composition`, then Commit
   typing. The editor boundary and explicit commit produce two accepted receipts.
2. Select the body, switch input source with Control-Space, and press
   `n i h o n n Space`. The OS displays the marked conversion `日本`.
3. Click Commit typing while conversion remains marked. The underline/selection
   remains, and authoritative state stays `Before composition`, 2 applications,
   2 receipts. No partial composition is submitted.
4. Click the title editor. Settlement waits while the original composition is
   still marked; the title cannot start another transaction. Return to body and
   confirm the conversion with Return twice. The underline disappears, `日本`
   settles once, and the counters reach 3/3. This is native input-method
   completion, not framework-forced unmarking.
5. With body focus, Command-Z restores the full baseline body (4/4), and
   Shift-Command-Z restores `日本` (5/5). The caret remains in the body; no
   partial phonetic fragments appear in the accepted receipts.
6. Arm Reject next edit. Select body and type
   `t o u k y o u Space Return Return`, then Commit typing. The view retains
   `東京`; authoritative state remains `日本`, 5 applications, 6 receipts,
   including exactly one rejection. Retry draft / reconcile accepts `東京`
   once (6 applications, 7 receipts).
7. Arm Delay next edit, select body and type
   `o o s a k a Space Return Return`, then Commit typing. The view shows `大阪`
   while editing is blocked; authoritative state remains `東京` at 6/7.
8. Switch to A with Command-`. Paste and commit `Independent peer`, Undo and
   Redo there. A reaches 3/3 independently. Returning to B still shows its
   original pending edit. Peer Undo does not touch B.
9. Release delayed outcome in B: `大阪` is accepted once (7 applications,
   8 receipts). Close / reopen preserves `大阪` with the same scope, working
   identity and counters. Quit the fixture through its normal graceful close.

The OS input-source list, U.S. selection, input-menu visibility, globe-key
behavior and automatically added dictation language were restored afterward.

**Result:** bounded actual AppKit IME observation passed. The rejected draft's
sample status text says “Pending authoritative outcome”; the rejection is
established by the authoritative rejected receipt and successful retry, rather
than that presentation label. This session does not qualify UIKit IMEs, other
languages, physical hardware keyboards, every native coalescing pattern, or
all selection ranges. Programmatic baseline-local-Redo checks remain separate
from the actual durable Undo/Redo observation above.

## Actual OS background-task expiry on iOS 17.5

Build/initial launch:

```sh
ruby scripts/run-durable-notes-uikit.rb --device 44BBA7E6-3AE1-4D7D-934C-D122C252FD31 --launch
```

Gracefully finish the initial interactive fixture, then launch a fresh fixture
using the app's existing CLI (no check flag):

```sh
xcrun simctl launch 44BBA7E6-3AE1-4D7D-934C-D122C252FD31 app.foliosuite.UndoKit.DurableNotesUIKit --undokit-uikit-fixture ExpiryObservation-20261018
```

Device: iPhone SE (3rd generation), iOS 17.5 (21F79), simulator. Original app PID
**6056**. Actual launch arguments contain only the fresh fixture argument;
`--undokit-uikit-check` and `UNDOKIT_UIKIT_CHECK=1` were absent. The injected
`UIKitChecks` path did not run. In this mode the existing
`NotesSceneOwner.backgroundExpired()` event can originate only from the
`UIApplication.beginBackgroundTask` expiration handler.

1. Starting with an empty note and zero receipts, tap Delay next edit, then
   Apply grouped example. The history becomes busy with one admitted two-field
   operation; authoritative state remains empty.
2. Externally launch `com.apple.Preferences`. The actual scene background event
   requests closure, which waits for the admitted delivery. A supervisor checks
   the original PID and event journal for at most 300 seconds; it never invokes
   expiry or advances an application clock.
3. At **2026-10-18T19:54:23.636968Z**, the observer retains
   `Background budget expired; closure not certified`. It was observed 13.6
   seconds after supervision began; this is not a measured OS budget. Before
   releasing delivery, the note still has zero receipts and effects.
4. Foreground the existing app: simctl returns the same PID 6056. The visible
   owner remains **closing**; semantic editing remains disabled. Expiry has not
   released ownership or claimed closure.
5. Tap Release delayed outcome. The original delivery drains, background
   closure completes, and the same document scope reopens ready. Tap
   Close / reopen again. Independent JSON readback shows one accepted receipt,
   exactly two members (title `Shopping`, body `Tea and bread`), one application,
   and the original scope and working identity. There is no partial group or
   duplicate accepted effect.
6. Finish sample after graceful close exits normally and records completed
   explicit closure. Shut down the simulator after observation.

**Result:** actual OS expiry and subsequent drain/closure/reopen passed on this
simulator. No reconciliation was needed: the original admitted delivery was
still running, then completed normally. This is not injected expiry, a
wall-clock inference, physical-device suspension proof, a forced-kill test,
or crash/abrupt-termination certification.

## Retained evidence

Durable root:
`~/Library/Developer/Xcode/DerivedData/UndoKit/Evidence/PostBeta/2026-10-18/`.

- `Observations/IME-*`: marked/completed/pending/reopened screenshots, raw
  authoritative snapshots, full closed fictional fixture and application log.
- `Observations/Expiry/`: supervisor result, before/after authoritative snapshots,
  callback and final closure event journals, UI screenshots and process identity.
- `AppKitSample/`: exact installed app, setup and build logs for the IME session.
- `UIKitExpirySample/`: exact installed app, setup/build logs for expiry.
- `Manifest.json`: hashes of the retained files.
