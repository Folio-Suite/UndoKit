# Add history to a UIKit scene

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Keep a native text view and its history binding with the scene's document presentation.

Use the `NoteDocument` wrapper from <doc:FirstUndoGroup>. The application owns its
``HistorySessions`` collection; the scene/controller owns an attachment. Share a
document owner between scenes that intentionally edit the same History Scope.

## Connect the editor and responder

```swift
import UIKit
import DurableNotesCore
import UndoKit

@MainActor final class NoteViewController: UIViewController {
    let editor = NativeHistoryTextView()
    private(set) var attachment: HistoryAttachment?
    private(set) var binding: NativeHistoryUIKitBinding?
    override var undoManager: UndoManager? { attachment?.undoManager }
    override var canBecomeFirstResponder: Bool { true }

    override func loadView() {
        view = editor
        editor.accessibilityLabel = "Note body"
    }

    func connect(document: NoteDocument) async throws {
        loadViewIfNeeded()
        let attachment = try document.history.attach(owner: self)
        self.attachment = attachment
        binding = try await attachment.bindUIKit(editors: [
            (editor, try document.lease.field(.body, in: document.history))
        ])
    }

    func disconnect() {
        binding?.disconnect()
        binding = nil
        attachment?.disconnect()
        attachment = nil
    }
}
```

Present the controller in your scene's window and retain the document owner in
your scene/application model. The native text view supplies UndoKit's manager
while UIKit owns typing, selection, paste, marked composition and live Undo/Redo.
Your explicit application controls can await `attachment.undo()` and `redo()`.

Keep the binding's delegate and input hooks installed. Use its `permitsEditing`
status for your own controls as well; native input admission is enforced by the
binding. A pending result does not grant a newly presented editor permission to
change the document.

## Commit, background and reopen

An explicit Save/Commit action can await `binding.commit()`. Inspect the result
and session status before proceeding. Native editing-end boundaries also settle
complete drafts. A submitted semantic operation uses the same shared session.

Backgrounding and protected-data changes are ownership events, not permission
to discard a pending effect. Stop admitting new UI work, give in-flight work a
bounded background opportunity to reach a recoverable boundary, and retain a
blocked owner if closure cannot finish. On return, close that owner successfully
before reacquiring returned storage with `.existing`.

The [UIKit sample](https://github.com/Folio-Suite/UndoKit/tree/main/Examples/DurableNotes/UIKit)
contains the complete scene lifecycle and protected-data handling. Start there
for production lifecycle wiring; the controller above intentionally shows only
the editor integration. Simulator observations do not establish physical locking,
hardware-keyboard or IME behavior.

## Topics

- ``HistoryAttachment``
- ``HistorySessionStatus``
- <doc:RecoveryAndStorage>
