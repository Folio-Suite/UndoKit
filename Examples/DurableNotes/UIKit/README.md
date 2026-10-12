<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Durable Notes for UIKit

A runnable iPhone/iPad UIKit host using the same `DurableNotesCore` as the
[AppKit sample](../README.md). Each `UIWindowScene` owns an independently
persisted title/body note, authoritative receipts and UndoKit history. The
framework receives opaque commands; the host owns the domain and its storage.

## Build and run

Open `DurableNotesUIKit.xcodeproj` in the selected Xcode 27.0 (27A266a), Swift 6.4
toolchain. The native target uses Swift 6 complete concurrency checking, declares
iOS 17 and supports iPhone/iPad. Choose an available simulator or configure your
own development team for a physical device. Physical qualification is separate.

The repeatable simulator runner requires an explicit device:

```sh
xcrun simctl list devices available
ruby scripts/run-durable-notes-uikit.rb --device DEVICE-UDID --launch
ruby scripts/run-durable-notes-uikit.rb --device DEVICE-UDID
ruby scripts/run-durable-notes-uikit.rb --device DEVICE-UDID --configuration Release
```

Use **Finish sample after graceful close** before starting a new check run. The
runner refuses an already running sample during checks. The finish control
drains and closes every owner before the example exits; it is a demonstration
control, not a production iOS termination pattern. Release deliberately delayed
work before finishing.

Builds use the locked stable shared `UIKitNotes` cache under
`~/Library/Developer/Xcode/DerivedData/UndoKit`. `UNDOKIT_DERIVED_DATA` overrides
the shared root. The app embeds one dynamic `UndoKit.framework`; the runner
removes absolute build/toolchain runtime search paths, verifies the signed
bundle, and checks the installed runtime's actual loaded path. These are
source-package observations, not downloadable XCFramework qualification.

Interactive state is inside the app container's
`Library/Application Support/DurableNotesUIKit/Interactive`. A scene's persisted
identifier selects its document directory. A registry and restoration activity
identify existing documents; restoration refuses an unavailable document
instead of creating a new scope. Preserve `Note.json`, `History.sqlite` and
`Owner.lock` together. The shared core acquires single-writer ownership before
opening/creating state; restored documents use an existing-only open path.

## Editing and routing

**Apply grouped example** edits title and body as one durable group. Toolbar
Undo/Redo works without an editor first responder. Focused semantic `UITextView`
Cmd-Z/Shift-Cmd-Z routes through the native responder chain to its scene's
history. **Local scratch** uses UIKit's transient text undo manager and consumes
local Undo even with an empty stack.

Typing stays provisional across event turns. **Commit / retry typing**, changing
editor focus, Undo/Redo or graceful lifecycle closure settles one semantic edit.
Native event-group closure alone does not submit each keystroke. Marked text
defers settlement and Undo until composition ends. This bounded sample is not a
complete text editor or broad IME qualification.

**Reject next edit** records proof of no effect. Rejected/failed settlement keeps
the provisional draft and requires explicit retry or discard. An Undo that
encounters rejection does not fall through to preceding accepted history.
**Delay next edit** creates a controlled pending delivery; **Release delayed
outcome** completes it. Delegate and native text-input barriers refuse semantic
changes and repeated inverses while preserving focus/selection. Local controls
and other scene scopes retain their own routing. Toolbar Undo/Redo availability
follows the focused history owner: local text can undo/redo during document
acceptance; returning focus to a semantic editor restores the pending barrier.
The other semantic buttons remain barred.

Debug exposes **Accept then fail finalization** using the real production save
failure seam. The host first atomically writes the effect and receipt; history
then fails finalization and suspends. **Close / reopen** reconciles that receipt
without another effect or changed receipt bytes. The failure API/control is
absent in Release.

## Scenes and lifecycle

**New independent scene** requests a real UIKit scene. iPad supports simultaneous
independent windows; iPhone can report multiple scenes unavailable. Activation
errors remain visible. Commands stay bound to their original owner when another
scene becomes active.

Background/disconnect settles nonmarked input, retains uncommitted/marked
drafts, drains outcomes and closes the store. Foreground reopens the existing
scope. Draft storage is nonauthoritative and requires a decision after reopening;
it is never replayed as an accepted effect. Opening/closing operations serialize
across callbacks. Availability is rechecked after asynchronous opening before
the owner becomes editable.

Background lease expiry reports closure as incomplete, disables semantic edits
and retains the owner until pending outcome and close finish. It does not
certify closure or release the writer merely because time expired. Protected
data callbacks hide content and request the same drain/close path. The storage
gate demonstrates policy; checks additionally move a closed document directory
away, verify restoration refuses replacement, then return the original files.

The host requests complete file protection for directories, note/receipts,
ownership/history files and atomic replacements. Simulators may not report
that attribute. Reports preserve the observation. Injected protection/expiry
callbacks test owner policy, not physical lock or actual OS budget expiration.
Real lock/unlock, protected-storage failure and hardware keyboard/IME behavior
remain separate gates.

## Checks and evidence

Each run uses a fresh fictional fixture and retains logs in `Evidence/UIKitNotes`.
`Setup.json` records commit/dirty source hashes, exact invocation, toolchain,
configuration, device identifier and signed binary hashes. `Fixture/Report.json`
is written only after all owners close successfully. It records runtime,
installed library path, scene identities, observations, lifecycle journals,
protection attribute and limitations. Failed fixtures/logs remain failures.

Checks run inside the installed UIKit app using real `UITextView`, `UITextInput`,
toolbar controls and responder dispatch. They cover grouped Undo/Redo,
provisional/marked typing, rejected drafts, local Undo, pending input/focus,
Debug receipt reconciliation, reopen and unavailable storage. On iPad they
request a second actual `UIWindowScene`, edit its independent scope while the
first outcome waits, and verify peer focus survives. The runner activates
Settings, waits for an actual UIKit background drain/close journal, then returns
the sample and verifies unchanged scope/application count. Injected policy
observations are labeled separately from those OS transitions.

A prefinal independent DeviceHub UI review on iPhone used the actual on-screen
keyboard for a typing run and one Undo, reopened the same receipt count,
observed empty local Undo isolation, and returned through Home to the same scene.
It exposed toolbar Undo without editor focus, now covered by a regression.
Those observations precede the final checkpoint and are not physical-keyboard,
broad human-IME or final immutable-head evidence.

Final selected-simulator results are recorded in the issue/PR with exact source
identity and retained report paths. This sample does not qualify the iOS floor,
Intel simulator, physical devices, abrupt termination, downloadable binary or
publisher signing. Broader gates in
[#8](https://github.com/Folio-Suite/UndoKit/issues/8) and onboarding contract in
[#10](https://github.com/Folio-Suite/UndoKit/issues/10) remain authoritative.
