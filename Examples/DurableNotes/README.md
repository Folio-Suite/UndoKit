<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Durable Notes

A small runnable AppKit host for UndoKit. Two document windows edit separate
persisted notes, each with a title and body. `DurableNotesCore` is a bounded,
Foundation-only host module shared with the [UIKit shell](UIKit/README.md).
It contains no AppKit routing or UI code.

## Build and run

Use the repository's selected Xcode 27.0 (27A266a), Swift 6.4 toolchain, Swift 6
language mode, and macOS 14 or later. The sample package also declares iOS 17 for
its shared core. The separate UIKit project and simulator runner are documented
in [UIKit/README.md](UIKit/README.md).

From the repository root:

```sh
ruby scripts/check-toolchain.rb
ruby scripts/run-durable-notes.rb --launch
```

The runner builds the local source-package dependency, embeds one UndoKit dynamic
library and its compiled model/privacy resource bundle, and ad-hoc signs a real
`.app`. It removes checkout/toolchain runtime search paths and the native checks
verify that the running app loaded exactly one UndoKit library from its own
`Contents/Frameworks`. This is a source-package sample, not a qualified native
project or XCFramework installation tutorial.

Build output uses the stable shared
`~/Library/Developer/Xcode/DerivedData/UndoKit/DurableNotes` directory. Set
`UNDOKIT_DERIVED_DATA` to override the shared root. A lock prevents simultaneous
runner builds. The runner replaces only its own generated app bundle; it keeps
the build cache and user data.

Interactive notes live at
`~/Library/Application Support/UndoKit-DurableNotes/Document-A` and `Document-B`.
To use a fresh fictional fixture without disturbing earlier notes, run the
generated executable with a new `UNDOKIT_NOTES_ROOT` directory:

```sh
UNDOKIT_NOTES_ROOT=/tmp/UndoKit-Notes-Example \
  "$HOME/Library/Developer/Xcode/DerivedData/UndoKit/DurableNotes/Installed/Debug/Durable Notes.app/Contents/MacOS/DurableNotesApp"
```

An existing fixture reopens its own history. Do not delete or replace one half of
a document to reset it: host state and history have independent durable roles.
Missing/corrupt state is refused, rather than replaced with an empty note. Quit
an interactive app before rebuilding its generated bundle.

## Repeatable observations

Start with a fresh fixture. Both windows initially show blank notes and zero
applications/receipts.

1. Click **Apply grouped example** in A. The title becomes `Shopping` and the
   body `Tea and bread`; applications and receipts become one. Focus the body
   and press Cmd-Z: both fields become blank together. Shift-Cmd-Z restores both.
2. Type ` and milk` at the end of the body. Text stays provisional while AppKit
   coalesces the typing run. **Commit typing**, changing editor focus, Undo,
   reopening, or graceful app termination settles the group. One Cmd-Z after
   typing commits then reverses that entire run. Native runloop group closure
   alone does not submit every keystroke. This sample chooses explicit semantic
   settlement boundaries; it is not a complete text-editor implementation.
3. Focus **Local scratch**. Its text has independent, nonpersisted native Undo.
   Cmd-Z with empty local history does nothing to the durable note. Copying,
   selection, and scrolling remain native AppKit operations.
4. During marked-text composition, semantic Undo/commit waits until composition
   finishes. The deterministic check uses the actual `NSTextInputClient`
   marked range. A particular human IME/input-source configuration remains a
   separate manual check; no broad IME qualification is claimed.
5. Click **Reject next edit**, then change the note or apply a different grouped
   example. The whole delivery is rejected with no domain effect. A rejected
   receipt is retained, but no accepted Action or partial Undo Group is created.
6. Click **Delay next edit**, then apply a changed note. A's semantic editors
   and repeated Undo/Redo are blocked while the authoritative outcome waits.
   Edit B and change focus to B; A's eventual completion must not steal focus or
   affect B. **Release delayed outcome** completes A. Release deliberately
   delayed work before quitting or reopening; closure waits for that delivery.
7. In Debug, click **Accept then fail finalization** from a different note.
   The host note changes to `Recovery` / `Durably accepted once`, its application
   count increases once, and a receipt is persisted. History finalization
   actually fails at its production Core Data save boundary. Semantic editing
   remains suspended. Click **Close / reopen**: history consults the existing
   host receipt, restores availability and leaves the host application count and
   receipt bytes unchanged. Cmd-Z reverses the complete recovered group.
   The injection method/button is absent in Release.
8. Undo, then **Close / reopen**. Redo remains available from the committed
   position. Opening and native attachment must not apply a host edit or replay
   native callbacks. Quit and launch again to observe ordinary persisted reopening.

The close button hides a window but retains its owner until graceful app
termination. A pending accepted outcome retains its original scope. This sample
does not redirect a transaction to whichever window is currently focused.

## Ownership and receipts

`Note.json` atomically stores the current note, stable scope/working identity,
application counter and authoritative receipts in one file replacement. Each
receipt is keyed by scope, generation, sequence and Command identity and retains
member identities plus versioned inverse/reapplication inputs. The host validates
every member against its expected prior value and prepares a candidate state
before committing the whole group. A rejected delivery persists proof of no
effect. Outcome lookup reloads authoritative evidence and never delivers again.

UndoKit's separately persisted `History.sqlite` coordinates opaque Commands,
accepted history, Undo/Redo position and reconciliation. Domain acceptance can
precede history finalization. Reconciliation uses the same prepared token and
the host's receipt; it must not invent a fresh Command or execute the effect
again. An ordinary new edit has a fresh Command identity and canonical encoded
intent. A retry of a previously submitted Command must preserve its identity,
fingerprint and members; do not recreate an edit as a substitute for lookup.

The host remains responsible for domain meaning, validation, authoritative
effects/receipts, payload interpretation and its own storage policy. UndoKit is
history infrastructure, not the primary datastore or a backup. The JSON example
supports one writer per document, with a process file lock acquired before host
initialization. It refuses duplicate opens and preserves existing state on
missing-file errors. It does not teach file coordination across cloud writers,
schema migration, receipt pruning, encryption or an unbounded production domain.
Each text field is bounded to 32 KiB. Atomic file replacement and graceful
close/reopen are the demonstration scope; abrupt termination is unqualified.

## Checks and retained evidence

```sh
ruby scripts/run-durable-notes.rb --check
ruby scripts/run-durable-notes.rb --check --configuration Release
```

Each run creates a fresh retained fixture and logs under the shared
`Evidence/DurableNotes` directory. `Setup.json` records source commit, dirty-file
hashes when applicable, exact command/toolchain/configuration, signed executable
and library hashes. `HostTests.log` records portable public-session tests.
`NativeFixture/NativeReport.json` records actual runtime/architecture, installed
UndoKit path, native observations and limits. Failed/aborted runs remain evidence
of failure and never count as passes. Native checks run inside the visible
installed AppKit app and use actual text controls, responder actions, marked
ranges, pending outcomes and reopening. They supplement the portable host tests.

The focused host tests cover grouped edit/Undo/Redo/reopen receipts, Debug
accepted-effect/failed-finalization reconciliation, atomic rejection and separate
scopes, missing host-state preservation, duplicate-writer refusal and
existing-only restoration without replacement storage creation. The root
`HistoryDebugFailureInjectionTests` exercises the public Debug API, including
busy refusal and inherited task-local isolation when independently owned stores
reuse both scope and Command IDs. Injection binds the selected engine owner too.

On 2026-10-12, the source-package installed app ran on an arm64 Mac with macOS
27.0.1 (26A434), Xcode 27.0 (27A266a)/Swift 6.4. Debug and Release host/native
checks passed. A separate CUA keyboard review observed grouped Cmd-Z/Shift-Cmd-Z,
complete native typing followed by one Cmd-Z, and empty local-history Undo
without document fallthrough. Visual review found readable, unclipped native
controls. The first keyboard review exposed premature per-event typing
submission; the corrected native regression checks that event-group closure
keeps typing provisional. The screenshot was displayed inline in the review;
the CUA API did not provide a file export.

These are selected-current-Mac observations, not macOS-floor, Intel, iOS,
physical-device, native-project, downloadable-binary, publisher-signing,
human-IME or abrupt-termination qualification. The release gates in
[#8](https://github.com/Folio-Suite/UndoKit/issues/8) and onboarding contract in
[#10](https://github.com/Folio-Suite/UndoKit/issues/10) remain the authority for
broader qualification.
