# Your first Undo Group

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Open a document, submit a typed edit, then Undo, Redo and reopen it.

## Run something first

Clone the repository, select Xcode 27.0 (27A266a), and run an example from its root:

```sh
ruby scripts/run-durable-notes.rb --launch
```

In **Document A**, choose **Apply grouped example**. Its title becomes `Shopping`
and its body becomes `Tea and bread`. Undo restores both fields together; Redo
restores both. Type into the body: native Undo/Redo now walks the live typing
history. **Commit typing** settles that draft into a durable Undo Group.

There are also [UIKit](https://github.com/Folio-Suite/UndoKit/tree/main/Examples/DurableNotes/UIKit),
[SwiftUI Mac](https://github.com/Folio-Suite/UndoKit/tree/main/Examples/DurableNotes/SwiftUIApp)
and [SwiftUI iPhone/iPad](https://github.com/Folio-Suite/UndoKit/tree/main/Examples/DurableNotes/SwiftUI)
apps. Their READMEs give launch commands and interactive exercises.

## Open one shared document session

The following snippets use `NotesDocumentLease` and `NoteChange` from the sample's
`DurableNotesCore` product. **Those are app-owned example types, not UndoKit API.**
The lease opens `Note.json`, retains its writer lock, and registers a typed change
handler. UndoKit owns the separate history database and draft journal.

Keep a ``HistorySessions`` collection in your app owner. Pass that same collection
when opening documents, and keep the returned document owner outside transient
views. This small wrapper is shared by the three platform guides:

```swift
import Foundation
import DurableNotesCore
import UndoKit

@MainActor final class NoteDocument {
    let history: HistorySession
    let lease: NotesDocumentLease
    let changes: HistoryCommands<NoteChange>

    private init(history: HistorySession, lease: NotesDocumentLease) throws {
        self.history = history
        self.lease = lease
        changes = try lease.commands(in: history)
    }

    static func open(
        at directory: URL, mode: HistoryOpenMode, in sessions: HistorySessions
    ) async throws -> NoteDocument {
        let lease = NotesDocumentLease(directory: directory)
        let history = await sessions.open(
            documentURL: directory, mode: mode, lease: lease
        ) {
            try await lease.setup(mode: mode)
        }
        guard history.status.phase == .ready else {
            throw history.status.issue ?? HistoryFailure(
                .storage, stage: .admission, disposition: .suspended)
        }
        return try NoteDocument(history: history, lease: lease)
    }
}
```

Use `.create` only for a deliberately new document, `.existing` when reopening a
known one. Persist the document's scope and working identity; never generate new
identities each launch to get around an opening failure. The sample stores them
in its domain file. A partial or missing known document is an error, not a reason
to create replacement history.

Open this wrapper **once per document**, then share it between presentations.
The lease and operation declaration have stable identity while open. The complete
sample registry also deduplicates requests for the same document and handles
blocked acquisition; use that pattern for a multiwindow app. A blocked session
remains retained by the application collection so recovery can finish.

## Submit application intent

Here is a rename button's action. Read the current title, filter a known no-op,
and submit a typed value. The example handler validates the expected title before
accepting it, so a stale read cannot overwrite a concurrent accepted edit.

```swift
@MainActor
func renameNote(_ document: NoteDocument, to title: String) async throws
    -> HistorySubmissionResult? {
    let oldTitle = try await document.lease.read().note.title
    guard oldTitle != title else { return nil }
    return await document.changes.submit(
        NoteChange(field: .title, expected: oldTitle, replacement: title))
}
```

For title and body changes that must succeed together, call `submitGroup` with
both values on the same typed handle. One host callback accepts the complete
ordered group atomically. Your editing call sites do not assign transaction
identities, encode payloads or take whole-document snapshots.

| Result | What your UI should do |
| --- | --- |
| `.accepted` | Show the accepted state; also check session readiness before enabling input. |
| `.rejected` | Explain that validation declined the request; no semantic effect was accepted. |
| `.unexecuted` | The request did not reach delivery. After resolving its cause, let the user submit fresh intent. |
| `.failed` | A usable failure was established. Inspect the failure and current status. |
| `.unresolved` | Keep recovery visible and editing blocked; reconcile the original request. |

The helper returns `nil` for its local no-op; that request never enters UndoKit.

## Undo, Redo and close

You can await `document.history.undo()` and `redo()` for application controls, or
supply a presentation attachment's UndoManager to native menus and responders.
The platform guides show the latter. Native live typing and settled application
history share that route without persisting each keystroke.

At the **document** ownership boundary, await `document.history.close()` and check
that its phase is `.closed`. A blocked close retains recovery ownership; do not
release or replace the domain resources prematurely. Closing one window of a
shared document only disconnects that window's attachment.

Reopen with `.existing`, read the host's state and receipts, and check Undo/Redo
availability. Reopening reconciles authoritative outcomes; it does not redeliver
accepted changes. Recovered field drafts require a deliberate retry/discard choice.

## Next

- <doc:AppKitIntegration>
- <doc:UIKitIntegration>
- <doc:SwiftUIIntegration>
- <doc:HostingYourModel>
- <doc:RecoveryAndStorage>
