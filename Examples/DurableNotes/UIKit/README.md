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

The [framework UIKit binding](../../../docs/uikit-history-binding.md) supplies
`NativeHistoryTextView`, a standard UITextView adapter overriding only its manager
getter. UIKit owns input, selection, paste, marked composition and the original
fine-grained live Undo stack. No text-input/action overrides or custom Undo key
commands are installed. Native assistant Undo/Redo uses that live stack until an
explicit editing transaction settles, including Redo after Undo reaches baseline.

**Commit / retry typing**, ending editing or moving to another bound editor, and
an explicit semantic action define coarse persisted boundaries. Pauses and
punctuation do not. **Apply grouped example** settles prior typing then proposes
a two-field Note group. Toolbar Undo/Redo follows the focused editor or document;
**Local scratch** remains an ordinary, independent UITextView and empty local
history never falls through to document history.

**Reject next edit** records authoritative proof of no effect. Active rejection
preserves usable local Undo/Redo and exact rejected evidence; a later explicit
boundary may prepare a new Command. Uncertainty blocks editing/inverses without
clearing live history or losing focus. Restored journals require explicit retry
or discard before new editing, including journals containing rejected intent.
Marked text prevents settlement without forced unmarking.

**Delay next edit** and **Release delayed outcome** exercise asynchronous
acceptance. The framework delegate barrier blocks native user editing while
admitted work is pending; host programmatic edits use the binding API. Scratch
and other scene scopes remain independent. Debug's finalization-failure seam
preserves accepted receipt evidence for exact retry; it is absent in Release.
No hardware keyboard or physical IME proof follows from programmatic checks.

## Scenes, ownership, and recovery

The app owns `NativeHistorySessions`. The domain lease owns Note meaning,
receipts and exclusive document acquisition; UndoKit owns draft journaling,
admission, settlement, draining and recovery retention. Scene adapters supply
platform availability, restoration mapping, protected-content visibility and
background-task budgets. They do not recreate generic queues or journal files.

**New independent scene** requests an actual UIKit scene; its durable scope
remains independent. Background drains admitted work and preserves unsettled or
marked values before complete closure; foreground reopens existing history.
A genuine presentation disconnect captures synchronously and releases recognized
local callbacks and controls even when the session's lease remains blocked.
Micro-history belongs to the live presentation, not the recovery journal.

Existing plain `{title,body}` Draft.json files from the former sample are refused
and preserved as incompatible evidence. Opening, retry or discard never silently
migrates, deletes, or replaces their bytes. Preserve Note.json, History.sqlite,
Owner.lock and available draft evidence together. No missing-document recovery
creates an empty replacement.

Complete file protection is requested for the document directory, current store
files/ownership files, atomic host replacements and typed journal. Simulator
attributes are recorded as observations; physical device-lock behavior remains
unqualified. Background budget expiry does not cancel delivered work or certify
closure merely because time elapsed.

## Checks and evidence

Each run uses a fresh fictional fixture and retains logs in `Evidence/UIKitNotes`.
`Setup.json` records commit/dirty source hashes, exact invocation, toolchain,
configuration, device identifier and signed binary hashes. `Fixture/Report.json`
is written only after all owners close successfully. It records runtime,
installed library path, scene identities, observations, lifecycle journals,
protection attribute and limitations. Failed fixtures/logs remain failures.

Checks run inside the installed UIKit app through the public binding with actual
UIKit controls and an independent durable host. They observe coarse receipts,
live Undo/Redo at baseline, active rejection/no-change and restored-decision gates,
marked/editor-switch boundaries, pending delegate/inverse barriers, Debug exact
reconciliation, reopen and weak controller/binding/control teardown while the
lease remains blocked. Unexpected facade registrations retain evidence across
disconnect until explicit certification. CheckStage.txt localizes failed cases. On iPad they
request a second actual `UIWindowScene`, edit its independent scope while the
first outcome waits, and verify peer focus survives. The runner activates
Settings, waits for an actual UIKit background drain/close journal, then returns
the sample and verifies unchanged scope/application count. Injected policy
observations are labeled separately from those OS transitions.

The standalone iPadOS 26.5 refined probe used actual software-keyboard keys and
assistant Undo/Redo to establish original-manager routing. Its seeded counter
was only a synchronous stand-in; installed production binding receipts/recovery
and interactive keyboard observations are recorded separately. Historical
prefinal UI observations do not qualify the final source checkpoint.

Final selected-simulator results are recorded in the issue/PR with exact source
identity and retained report paths. This sample does not qualify the iOS floor,
Intel simulator, physical devices, abrupt termination, downloadable binary or
publisher signing. Broader gates in
[#8](https://github.com/Folio-Suite/UndoKit/issues/8) and onboarding contract in
[#10](https://github.com/Folio-Suite/UndoKit/issues/10) remain authoritative.
