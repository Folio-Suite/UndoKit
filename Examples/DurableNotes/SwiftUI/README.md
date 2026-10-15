<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Durable Notes in SwiftUI on iPhone and iPad

Open `DurableNotesSwiftUI.xcodeproj` in Xcode 27.0 and run the
`DurableNotesSwiftUI` scheme. It links the UndoKit source package and the shared
`DurableNotesCore` domain package. Deployment starts at iOS/iPadOS 17. Leave
Xcode's Derived Data setting at its system default.

From the repository root, the repeatable installed check is:

```sh
ruby scripts/run-durable-notes-swiftui-ios.rb --device <simulator-UDID> --launch
ruby scripts/run-durable-notes-swiftui-ios.rb --device <simulator-UDID>
ruby scripts/run-durable-notes-swiftui-ios.rb --device <simulator-UDID> --configuration Release
```

The runner installs one selected simulator at a time and retains exact build,
configuration, source hashes, runtime observations and an independent `Note.json`
readback under `~/Library/Developer/Xcode/DerivedData/UndoKit/Evidence/DurableNotesSwiftUIiOS`.
Xcode still resolves its configured default build location. The runner boots the selected simulator only when
needed and shuts it down only when it owns that boot. Use the available iPadOS
26.5 simulator for the tracked iPadOS 27 startup exclusion. These observations
supplement existing preview gates; they do not add a new release gate.

## Small integration boundary

Each scene owns one `SwiftUINotesOwner` through `@StateObject`. That owner retains
the standard native text controls, `NativeHistoryUIKitBinding` and
`NativeHistorySession`; transient SwiftUI value views only present them.
`NativeHistorySwiftUIEditor(textView:)` wraps the standard UIKit control. SwiftUI
values hold a weak editor reference, while the mounted native container retains
its subview. The scene owner keeps that editor alive between presentations;
cached SwiftUI values do not retain it after genuine owner teardown. The adapter
leaves text input, selection, composition, paste and native Undo callbacks in
UIKit. It uses no private API, SwiftUI view-tree lookup, custom input engine or
replacement keyboard shortcut.

Same-turn `.id` replacement can create the new native container before SwiftUI
dismantles the old one. The adapter keeps a weak waiting presentation and mounts
it as soon as the old presentation releases the editor. Simultaneous active
presentations display an attachment diagnostic instead of stealing the editor.

Create the binding once with `session.connectUIKit(owner:editors:localEditors:...)`.
Supply domain draft capture/rendering and status presentation. Present each
editor in one location at a time. Give another scene its own editor, session and
stable document identity. Never connect again from `body` or `updateUIView`.

Apply `.nativeHistory(binding)` to SwiftUI command controls and read
`@Environment(\.nativeHistoryUndoManager)` to invoke its facade. The SDK's standard
`EnvironmentValues.undoManager` is read-only on iOS. Native assistant and
responder actions still route through the native editor's `undoManager`; the
explicit environment key supplies the same facade to SwiftUI buttons.

The sample observes the facade's `NSUndoManagerCheckpoint` notifications and
native editing begin/end notifications to refresh the SwiftUI buttons' local
eligibility state. Native Undo can change `canUndo`/`canRedo` while the durable
status text stays identical. Observing only that status left the buttons stale
in an actual iPad software-keyboard check. After native Undo reaches the live
baseline, SwiftUI Undo must disable and Redo enable; Redo reverses that state.
Rebuilding the editor presentation releases focus, so both live buttons disable
until refocusing an editor supplies its native route again.

## Transactions and lifetime

Typing, native Undo and baseline Redo stay local while the editing transaction
is open. **Commit typing**, a genuine focus change between editors, or explicit
durable Undo settles a coarse persisted Undo Group. View reconstruction,
conditional removal, navigation and reattachment preserve native callbacks.
The framework defers SwiftUI-managed editing-end classification through the
synchronous presentation transition; a recorded disappearance remains a detach
even if the editor reappears before classification. Visible-editor focus moves
still establish an admission barrier before another edit.

The scene closes and drains its retained session on backgrounding and protected-data
unavailability, then reopens that same owner when access returns. Unsettled
drafts reopen with an explicit decision; retry or discard is the host's visible
choice. A real presentation teardown calls `binding.disconnect()` and closes the
session. The application-level `NativeHistorySessions` collection retains any
blocked recovery owner until complete closure succeeds. Dropping a SwiftUI view
is never permission to discard unresolved evidence.

Scene IDs use `@SceneStorage`, read inside the mounted task. A durable registry
separates creation from existing-only restoration. Missing original stores and
unreadable registry data refuse opening instead of creating replacement data.
The example's protected-data policy hides content and disables native document
commands immediately; the domain lease retains its original scope and receipts.

## What the installed checks observe

The in-app checks use actual UIKit text controls inside the SwiftUI host. They
exercise local native Undo/Redo, coarse acceptance, durable Undo/Redo, reopen,
view reconstruction/navigation, visible-editor focus changes, scratch priority,
marked ranges, rejection, delayed admission, Debug finalization uncertainty,
original-storage preservation and injected protected-data policy. The runner
also performs an actual Settings background/foreground transition. The iPad
route requests a second real `UIWindowScene` and verifies a separate durable
scope; the iPhone route records that multi-window isolation belongs to iPad.

A temporary mounted SwiftUI presentation encounters a real journal-path
obstruction. After disconnecting callbacks, ending transient native focus and
restoring focus/accessibility to the known original editor, weak references observe release of its scene owner, native editor, binding and hosting
controller while the application collection retains the exact blocked session
and lease. Repairing only the known obstruction permits complete closure. Its
unsettled journal then reopens independently, remains decision-gated, and accepts
through explicit retry exactly once. These checks distinguish presentation
release from complete recovery-resource closure.

Programmatic `insertText`/`setMarkedText` and injected protection availability
are deterministic policy observations. They do not qualify a human IME, hardware
keyboard, physical device lock or forced termination. Runtime and configuration
results must come from each retained run; a build alone is not a passing check.
