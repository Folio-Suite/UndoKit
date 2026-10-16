<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Durable Notes

The [SwiftUI Mac host](SwiftUIApp/README.md) provides the same example with native-backed SwiftUI editors.

A small runnable AppKit host using UndoKit's supported
[AppKit binding](../../docs/appkit-history-binding.md) and shared History Session.
Two document windows edit separate
persisted notes, each with a title and body. `DurableNotesCore` is a bounded,
Foundation-only host module shared with the [UIKit shell](UIKit/README.md)
and [SwiftUI iPhone/iPad shell](SwiftUI/README.md).
It contains no AppKit routing or UI code.

## Shared typed integration

The application retains a `HistorySessions` collection. `NotesDocumentLease` acquires only the domain file and exclusive writer lock. Session setup declares `HistoryOperation<NoteChange>` once, binding the typed host handler, JSON codecs and canonical intent fingerprint. UndoKit acquires and closes its own history resources before releasing that domain lease.

```swift
let lease = NotesDocumentLease(directory: directory)
let session = await lease.openSession(in: sessions, mode: .existing)
let commands = try lease.commands(in: session)
await commands.submitGroup([
    NoteChange(field: .title, expected: "", replacement: "Shopping"),
    NoteChange(field: .body, expected: "", replacement: "Tea and bread")
])
let attachment = try session.attach(owner: windowController)
let binding = try await attachment.bindAppKit(editors: [
    (titleEditor, try lease.field(.title, in: session)),
    (bodyEditor, try lease.field(.body, in: session))
])
```

Keep the attachment with the presentation. Each field supplies its own stable identity, mapping and authoritative revision; equal strings do not establish equal revisions. Ordinary edits, native settlement, durable Undo/Redo and recovery share one session admission owner. Results distinguish accepted/rejected work from unexecuted requests and unresolved delivered work. A successfully closed session and its handles are retired; reopening acquires a fresh session for the same durable scope.

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
`KnownDocuments.json` records discovery outside the document directories before
initial creation. A previously known missing document or any partial existing
artifact always selects existing-only acquisition, including across app relaunch;
missing/corrupt state is refused without replacement. Keep this registry with the
app root. Loss of the entire registry and root cannot establish prior identity and
is outside this bounded sample's discovery model. Quit
an interactive app before rebuilding its generated bundle.

## Repeatable observations

Start with a fresh fixture. Both windows initially show blank notes and zero
applications/receipts.

1. Click **Apply grouped example** in A. The title becomes `Shopping` and the
   body `Tea and bread`; applications and receipts become one. Focus the body
   and press Cmd-Z: both fields become blank together. Shift-Cmd-Z restores both.
2. Type ` and milk` at the end of the body. Cmd-Z/Shift-Cmd-Z use fine native
   live Undo/Redo, including Redo after returning to the committed baseline. No
   durable delivery occurs for those live steps. **Commit typing**, an actual
   editing-end/focus boundary or a host semantic action persists the whole editing
   transaction as one durable group. Native event-group closure alone does not
   persist each keystroke. The explicit `undoDocument()` API settles then reverses
   the newly accepted transaction; rejection or uncertainty stops that invocation.
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
   remains suspended; in-place reconciliation preserves the same evidence. Click **Close / reopen** to acquire a clean context and
   finalize the original prepared Command. The host application count and exact
   receipt bytes stay unchanged, with zero new delivery callbacks. Cmd-Z reverses
   the complete recovered group once recovery has succeeded.
   The injection method/button is absent in Release.
8. Undo, then **Close / reopen**. Redo remains available from the committed
   position. Opening and native attachment must not apply a host edit or replay
   native callbacks. Quit and launch again to observe ordinary persisted reopening.

The close button hides a window but retains its owner until graceful app
termination. Closing or disconnecting preserves unsettled draft evidence;
reopening that evidence requires **Retry draft** or **Discard draft**. A pending
or uncertain prepared Command cannot be discarded until its authoritative outcome
permits it. The sample keeps no generic editing queue: `NotesDocumentLease` owns
Note semantics and receipts, while `HistorySession` and the binding own
admission, journaling, settlement, callback cleanup and recovery. A pending accepted outcome retains its original scope. This sample
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

Before the shared History Session migration, the source-package installed AppKit host passed Debug on 2026-10-15
and Release public-session and native-control checks on the selected arm64 Mac
with macOS 27.0.1 (26A434), Xcode 27.0 (27A266a)/Swift 6.4. The runner now includes
all `Notes` host, native-session and AppKit-binding tests. Binding checks cover
failed authoritative refresh/exact retry, unknown callback retention through
blocked closure until explicit reconciliation, unavailable storage without
replacement, weak owner teardown, and retained-draft retry decisions.

Separate actual CUA keyboard/menu review typed `Alpha`, used repeated Cmd-Z to
reach its baseline, observed Undo disabled/Redo enabled in the real Edit menu,
clicked menu Redo and used Shift-Cmd-Z to restore `Alpha`. Independent `Note.json`
reads showed zero durable deliveries for live editing, exactly one application and
receipt after Commit typing, and three after durable Undo/Redo. Native scratch
Undo to empty plus extra Cmd-Z left the document and its three receipts unchanged.
The first review exposed missing standard responder actions/menu availability;
the corrected adapter and public regression address that failure. CUA's image
surface was unavailable during this review, so no new visual-layout qualification
is claimed. Programmatic control/responder checks are recorded separately from
that actual keyboard evidence. Their source hashes, runtime identity and exact
commands are retained by each runner invocation.

These are selected-current-Mac observations, not macOS-floor, Intel, iOS,
physical-device, native-project, downloadable-binary, publisher-signing,
human-IME or abrupt-termination qualification. The release gates in
[#8](https://github.com/Folio-Suite/UndoKit/issues/8) and onboarding contract in
[#10](https://github.com/Folio-Suite/UndoKit/issues/10) remain the authority for
broader qualification.
