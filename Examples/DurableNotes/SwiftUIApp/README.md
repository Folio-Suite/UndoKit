<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Durable Notes in SwiftUI on macOS

A minimal SwiftUI window content host backed by standard AppKit editors and the
[supported SwiftUI integration](../../../docs/swiftui-appkit-history-binding.md).
It shares the independently persisted Note semantics, receipts and native session
with the [AppKit example](../README.md).

```sh
ruby scripts/run-durable-notes-swiftui-macos.rb --launch
ruby scripts/run-durable-notes-swiftui-macos.rb --check
ruby scripts/run-durable-notes-swiftui-macos.rb --check --configuration Release
```

The runner uses the established shared build root and records exact source,
dirty-file hashes, configuration, toolchain and signed executable/library hashes
in `Evidence/DurableNotesSwiftUI`. It installs a signed source-package app at
`~/Library/Developer/Xcode/DerivedData/UndoKit/DurableNotesSwiftUI/Installed/Debug/Durable Notes SwiftUI.app`.
Use the corresponding `Release` path for Release. No custom Xcode Derived Data
location is required. Quit the app before replacing its generated bundle.

Interactive files live in
`~/Library/Application Support/UndoKit-DurableNotes-SwiftUI`. Launch the executable
with `UNDOKIT_SWIFTUI_NOTES_ROOT=/tmp/a-fresh-fictional-fixture` to isolate a run.
Existing documents use existing-only acquisition through the shared discovery
registry. Never reset a document by deleting only its host state or history.

Type `Alpha` in Body, use standard Cmd-Z/Shift-Cmd-Z and inspect the real Edit
menu at the baseline. No durable application is delivered for these live steps.
**Rebuild SwiftUI editor views** forces `.id` reconstruction; the same editor,
selection and live manager survive. **Commit typing** settles one durable group;
subsequent native Undo/Redo uses durable history. **Apply grouped example** changes
both note fields in one group. The local scratch editor retains isolated native
Undo and an empty stack never falls through to the document's history.

The recovery, marked-text, delayed-outcome, rejection and close/reopen buttons
follow the AppKit example's observation sequence. Debug additionally demonstrates
accepted-effect/failed-finalization reconciliation at the real history save
boundary. A failed writable context requires **Close / reopen**; clean acquisition
finalizes the exact existing receipt with zero new host delivery callbacks.
Uncertain replies on a still-writable store can reconcile in place.
The owner renders authoritative text only when its value changes, preserving
native selection during unchanged refreshes.

Closing a window releases its SwiftUI graph, editors and binding. The application
retains complete blocked session/lease ownership without retaining all closed
editors. File > Open Document A/B reattaches those identities. Graceful app quit
refuses unresolved closure. **Close / reopen** closes and opens a replacement session for the same scope
and attaches a fresh presentation; retained drafts require an explicit
Retry/Discard decision. Release intentionally delayed outcomes before quitting.

`--check` runs public-session/native-binding tests and the installed SwiftUI app
with actual `NSHostingView` content. Its retained `NativeReport.json` records native
control/responder observations, real SwiftUI identity reconstruction, independent
host receipts/reopen, runtime architecture and loaded embedded UndoKit identity.
Weak teardown tests dispose a real SwiftUI host while blocked recovery retains
unknown registration evidence. Programmatic `NSTextInputClient` composition is
separate from human input-source/IME qualification; actual keyboard/menu review
is reported separately from responder API checks. Floor macOS, Intel, publisher
signing, binary distribution and forced termination remain unqualified.

Historical evidence from before this shared-session migration: on 2026-10-15, the selected arm64 Mac running macOS 27.0.1 (26A434), Xcode
27.0 (27A266a) and Swift 6.4 passed Debug (18 Notes tests) and Release (17),
plus both installed native harnesses. Retained evidence is under the shared
`Evidence/DurableNotesSwiftUI` root, runs `20261015T175732Z-6fd29e` (Debug)
and `20261015T175807Z-214e28` (Release). Historical Setup commands use the runner's
original `run-durable-notes-swiftui.rb` name; it was subsequently renamed with
`-macos` to coexist with the independent iOS runner. This rename changes no
runtime source. Actual keyboard/menu observations remain separate from these
programmatic native reports.
