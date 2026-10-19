# ``UndoKit``

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Durable Undo and Redo for Swift apps, with the native editing behavior people expect.

Let someone type, undo a few keystrokes, commit an edit, and reopen the document
later with its application history intact. UndoKit coordinates that history;
your app keeps its own model, storage and meaning.

## Build your first integration

Start with <doc:InstallingUndoKit>, then follow <doc:FirstUndoGroup>. The guide
uses the small, persisted **Durable Notes** example so you can run the code and
inspect the resulting document and receipts. Choose a presentation:

| Your app | Continue here |
| --- | --- |
| AppKit windows and text views | <doc:AppKitIntegration> |
| UIKit view controllers and scenes | <doc:UIKitIntegration> |
| SwiftUI on Mac, iPhone or iPad | <doc:SwiftUIIntegration> |

@Image(source: "HistoryOwnership", alt: "The application retains one History Session per document scope. Windows and SwiftUI views attach to that session. Typed commands reach the host, which commits domain data and outcome receipts together; UndoKit stores history separately.")

One document has one shared ``HistorySession``, even when several windows display
it. A window owns a ``HistoryAttachment``. Closing a presentation disconnects that
attachment; closing the document explicitly closes its session.

## What you implement

Your host defines the operations your app understands, applies each complete
Undo Group atomically, and stores authoritative outcome receipts with its data.
Register the operation once; editing code receives a typed ``HistoryCommands``
handle. Native text bindings use the same operations at editing boundaries.

UndoKit supplies ordering, durable history, native UndoManager routing, draft
journaling and recovery coordination. It does not replace your primary datastore
or turn arbitrary UndoManager callbacks into persistent operations.
<doc:HostingYourModel> explains the host adapter and receipt contract.

## When something goes wrong

Await ``HistorySubmissionResult`` and observe ``HistorySessionStatus``. An accepted
Command may still need an authoritative presentation refresh before editing can
resume. Unresolved work keeps its original identity for reconciliation; submitting
a new request is not a recovery strategy.

Use `.create` for a new document and `.existing` for a known one. Missing or corrupt
existing history is preserved and refused. See <doc:RecoveryAndStorage> for
recovery, draft decisions and closure, and <doc:RetainedHistoryAndResources> when
you need browsing, checkpoints or retention beyond ordinary Undo/Redo.

## Beta support

The intended beta targets macOS 14 and iOS/iPadOS 17 with Xcode 27.1 / Swift 6.4.
Versions `0.2.0` and `0.2.1` are published beta releases. Version `0.2.2` is
being prepared as a candidate and remains subject to change until published with
its matching qualification evidence. Use the documentation and evidence
matching your selected source or release; see
<doc:PreviewCompatibilityAndSupport>.

## Topics

### Get started

- <doc:InstallingUndoKit>
- <doc:FirstUndoGroup>
- <doc:AppKitIntegration>
- <doc:UIKitIntegration>
- <doc:SwiftUIIntegration>
- <doc:HostingYourModel>

### Application and document ownership

- ``HistorySessions``
- ``HistorySession``
- ``HistorySessionConfiguration``
- ``HistorySessionSetup``
- ``HistoryHostLease``
- ``HistorySessionStatus``

### Commands and native editing

- ``HistoryOperation``
- ``HistoryCommands``
- ``HistorySubmissionResult``
- ``HistoryAttachment``
- ``HistoryField``
- ``HistoryFieldSnapshot``
- ``NativeHistorySwiftUIEditor``

### Recovery and retained history

- <doc:RecoveryAndStorage>
- <doc:RetainedHistoryAndResources>
- <doc:PreviewCompatibilityAndSupport>
- ``HistoryFailure``
- ``HistoryReading``
- ``HistoryRetentionManaging``

### Advanced host integration

- ``HistoryOperationHandler``
- ``MainActorHistoryOperationHandler``
- ``HistoryCodec``
- ``HistoryTransactions``
- ``HistoryStore``
- ``HistoryEngine``
