# Add history to an AppKit window

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Bind native text views to a document's typed operations and route the window's UndoManager.

Start with the `NoteDocument` wrapper in <doc:FirstUndoGroup>. Create one
presentation owner per window, sharing that wrapper when two windows show the
same document. This example binds the body field; the runnable app also binds a
title and demonstrates a local scratch editor.

## Connect the editor

```swift
import AppKit
import DurableNotesCore
import UndoKit

@MainActor final class NoteWindow: NSWindow {
    weak var historyManager: UndoManager?
    override var undoManager: UndoManager? { historyManager }
    @objc func undo(_ sender: Any?) { historyManager?.undo() }
    @objc func redo(_ sender: Any?) { historyManager?.redo() }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return historyManager?.canUndo ?? false }
        if item.action == #selector(redo(_:)) { return historyManager?.canRedo ?? false }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor final class NoteWindowHistory {
    let editor = NativeHistoryAppKitTextView()
    private(set) var attachment: HistoryAttachment?
    private(set) var binding: NativeHistoryAppKitBinding?

    func connect(document: NoteDocument, window: NoteWindow) async throws {
        editor.isRichText = false
        editor.allowsUndo = true
        let attachment = try document.history.attach(owner: self)
        self.attachment = attachment
        binding = try await attachment.bindAppKit(editors: [
            (editor, try document.lease.field(.body, in: document.history))
        ])
        window.historyManager = attachment.undoManager
    }

    func disconnect() {
        binding?.disconnect()
        binding = nil
        attachment?.disconnect()
        attachment = nil
    }
}
```

Retain `NoteWindowHistory` in your window controller. Place its `editor` inside an
`NSScrollView` and install that scroll view in the window's content view. For an
`NSDocument` app, provide the same attachment manager through the document's
normal UndoManager route instead of inventing another manager.

The field declaration reads the authoritative value **and revision** and maps a
proposed string to the same `NoteChange` operation used by the rename button.
Binding installs the native editing hooks; do not replace its text-view delegate
or register a second set of live Undo callbacks.

## Commit and report readiness

Await `binding.commit()` at an explicit **Commit typing** action. Supported
focus/editing-end boundaries also settle drafts. An event-loop Undo group ending
is not itself a request to persist each keystroke.

Observe `HistorySessionStatus` through `session.attach(owner:statusDidChange:)`
when connecting. Use `binding.permitsEditing` and the status to update controls
and explain busy/recovery states. Preserve marked text while composition finishes;
do not overwrite a live draft from a background model refresh.

Before closing a window, settle its editing and handle rejection or recovery
visibly. Then disconnect its presentation. If it was the last owner of the
**document**, explicitly await session closure and check `.closed`.

## Try it

In the [AppKit sample](https://github.com/Folio-Suite/UndoKit/tree/main/Examples/DurableNotes),
type, use Cmd-Z/Shift-Cmd-Z, commit, then close and reopen. A local scratch editor
uses only its own history: an empty local Undo stack must not fall through to an
older document edit. Two windows for the same document share session ordering;
two different documents keep independent scopes.

## Topics

- ``HistoryAttachment``
- ``HistoryField``
- <doc:RecoveryAndStorage>
