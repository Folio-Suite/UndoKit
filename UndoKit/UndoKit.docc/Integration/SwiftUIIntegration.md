# Present native history in SwiftUI

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Let SwiftUI compose the screen while a stable owner retains the editor, binding and session.

Use the document setup in <doc:FirstUndoGroup> and the appropriate native binding
from <doc:AppKitIntegration> or <doc:UIKitIntegration>. ``NativeHistorySwiftUIEditor``
presents that **existing** editor. It does not open another session or turn a
SwiftUI `TextEditor` into durable history.

## Keep native objects outside the view value

This presentation owner holds one bound native editor and publishes session
status. It shares the `NoteDocument` from the first guide rather than opening its
own session. The platform-specific part is only the native editor and binding:

```swift
import SwiftUI
import UndoKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor final class SwiftUINotePresentation: ObservableObject {
    #if canImport(AppKit)
    let editor = NativeHistoryAppKitTextView()
    @Published private(set) var binding: NativeHistoryAppKitBinding?
    #else
    let editor = NativeHistoryTextView()
    @Published private(set) var binding: NativeHistoryUIKitBinding?
    #endif
    @Published private(set) var status: HistorySessionStatus
    private let document: NoteDocument
    private var attachment: HistoryAttachment?

    init(document: NoteDocument) {
        self.document = document
        status = document.history.status
    }

    func connect() async throws {
        guard attachment == nil else { return }
        let attachment = try document.history.attach(owner: self) { owner, status in
            owner.status = status
        }
        self.attachment = attachment
        do {
            let body = try document.lease.field(.body, in: document.history)
            #if canImport(AppKit)
            editor.isRichText = false
            editor.allowsUndo = true
            binding = try await attachment.bindAppKit(editors: [(editor, body)])
            #else
            binding = try await attachment.bindUIKit(editors: [(editor, body)])
            #endif
        } catch {
            attachment.disconnect()
            self.attachment = nil
            throw error
        }
    }

    func disconnect() {
        binding?.disconnect()
        binding = nil
        attachment?.disconnect()
        attachment = nil
    }
}
```

Keep this owner in your application's scene/document model (for example with
`@StateObject`). Await `connect()` before presenting the editor and display any
opening error. The view observes the existing owner:

```swift
@MainActor struct NoteEditor: View {
    @ObservedObject var presentation: SwiftUINotePresentation

    var body: some View {
        if let binding = presentation.binding {
            VStack {
                NativeHistorySwiftUIEditor(textView: presentation.editor)
                NoteUndoButtons(status: presentation.status)
                if presentation.status.isEditingBlocked {
                    Text("Editing is paused; check the document's recovery status.")
                }
            }
            .nativeHistory(binding)
        } else {
            ProgressView("Opening note…")
        }
    }
}
```

Supply a visible retry/discard decision when `status.requiresDraftDecision` is
true, and surface `status.issue` in your app's error presentation. Do not blindly
discard a draft to make the status message disappear.

Do not also install this editor in an AppKit/UIKit parent. Let the wrapper own
its visual placement. When values overlap during replacement, one container
presents the editor and surviving waiters receive it in order. Do not infer that
`.onDisappear` means a native container was destroyed; SwiftUI can retain
offscreen content.

## Route explicit Undo controls

The modifier supplies UndoKit's `nativeHistoryUndoManager` environment value.
A toolbar can obtain it without creating its own UndoManager:

```swift
import SwiftUI
import UndoKit

struct NoteUndoButtons: View {
    let status: HistorySessionStatus
    @Environment(\.nativeHistoryUndoManager) private var history

    var body: some View {
        HStack {
            Button("Undo") { history?.undo() }
                .disabled(!status.canUndo)
            Button("Redo") { history?.redo() }
                .disabled(!status.canRedo)
        }
    }
}
```

Place these controls **inside** the subtree receiving `.nativeHistory(binding)`.
The observed owner forwards session status to these buttons so availability
updates redraw them. Reading UndoManager properties alone does not subscribe a
view to changes. The SDK's built-in `undoManager` environment value is not the
writable integration point. On Mac, also supply the binding's manager to the
window/document responder route for Edit-menu commands and keyboard shortcuts.

Keep one editor/binding per presentation in your stable owner. Rebuilding a view
must not create another writer, replace the native manager, or lose pending and
rejected drafts. Disconnect when the presentation is actually retired; close the
shared session only when its document lifetime ends.

## Run the complete apps

- [SwiftUI Mac](https://github.com/Folio-Suite/UndoKit/tree/main/Examples/DurableNotes/SwiftUIApp)
- [SwiftUI iPhone/iPad](https://github.com/Folio-Suite/UndoKit/tree/main/Examples/DurableNotes/SwiftUI)

Both share the same durable Note/receipt host. They demonstrate rejected and
pending drafts, remounting, native Undo/Redo and explicit retry/discard decisions.

## Topics

- ``NativeHistorySwiftUIEditor``
- ``HistoryAttachment``
- <doc:RecoveryAndStorage>
