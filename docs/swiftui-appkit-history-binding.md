<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# SwiftUI macOS editing

Use `NativeHistorySwiftUIEditor(textView:)` to present a supported
`NativeHistoryAppKitTextView` inside SwiftUI. Create the editor, one
`NativeHistorySession` connection and its `NativeHistoryAppKitBinding` in a stable
presentation owner, rather than in `body` or `makeNSView`. Retain the complete
lease through an application-owned `NativeHistorySessions` collection. The
[AppKit binding contract](appkit-history-binding.md) remains authoritative for
settlement, recovery, marked text and unknown registrations.

```swift
if let binding = document.binding {
    NativeHistorySwiftUIEditor(textView: document.bodyEditor)
        .nativeHistory(binding)
}
```

The editor's standard responder actions route native Edit menu and keyboard
Undo/Redo. The adapter uses public `NSViewRepresentable`, `NSScrollView` and
`NSTextView` APIs; it does not inspect SwiftUI's private hierarchy or install
keyboard handlers. `.nativeHistory(binding)` publishes
`EnvironmentValues.nativeHistoryUndoManager` for explicit SwiftUI buttons.
SwiftUI's built-in `undoManager` environment is getter-only and is not replaced.
The sample retains the standard AppKit Edit menu rather than substituting
SwiftUI Undo commands. Menu validation queries the focused editor each time;
SwiftUI button availability follows the owner's published status updates.

Identity changes can make SwiftUI create a replacement representation before
it dismantles the old one. Framework-owned weak presentation coordination waits
for that release, then mounts the same native editor and manager. A simultaneous
second representation displays an unavailable-editor message instead of stealing
the first presentation. No new session, connection or writer is created by a
representable update. A view value holds only a weak editor reference; the stable
owner must retain its editor. Live typing history remains native across remounts.

Genuine window closure has a different purpose from representable reconstruction.
Release the SwiftUI root and presentation owner, disconnect the binding to capture
and journal its draft, and request session closure. Keep the application session
collection alive if closure is blocked. The sample removes its closed window and
document owner immediately; it retains only lease/session resources and permits
reattaching from File > Open Document A/B. It refuses app termination while a
retained session cannot close. Pending delivery must be released before trying to
quit; completion cannot change the document selected by another window or steal
its focus. A restored draft retains its explicit Retry/Discard decision gate.

See the [runnable SwiftUI Mac host](../Examples/DurableNotes/SwiftUIApp/README.md)
for installation, repeatable checks, identity evidence and qualification limits.

The iOS SwiftUI integration can expose the same editor/environment vocabulary
while retaining platform-specific native controls. A later consolidation may
share public documentation and observation helpers; the AppKit presentation
handoff and UIKit original-manager behavior should remain distinct unless runtime
evidence establishes a common contract. This slice removes no existing APIs.
