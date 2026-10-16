<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# AppKit field bindings

Attach each window to its shared `HistorySession`, then bind
`NativeHistoryAppKitTextView` controls to `HistoryField<String>` declarations.
Each declaration reads its authoritative value/revision and creates typed semantic
Commands from that exact base. The host no longer captures a whole-document draft
or owns a parallel store/engine lifecycle.

```swift
let attachment = try session.attach(owner: controller,
    statusDidChange: { owner, status in owner.show(status) })
let binding = try await attachment.bindAppKit(
    editors: [(controller.titleEditor, titleField),
              (controller.bodyEditor, bodyField)],
    localEditors: [controller.scratchEditor])
```

Supply `attachment.undoManager` through the normal window/document/responder
provider. Keep the attachment and binding in the presentation owner. Standard Edit
menu actions and keyboard commands retain native routing; no alternate text-input
system is needed. Binding callbacks weakly retain their presentation owner.

AppKit's text editor and text storage register against the supplied facade. Exact
recognized targets forward to a dedicated native live manager. Event grouping,
coalescing, selection, marked text and native notifications stay in AppKit. This
mechanical distinction from UIKit is intentional; transaction policy is shared.

Live Undo/Redo remains on that live stack, even when Undo reaches the original
baseline. Commit or a supported focus boundary settles the field transaction through
the session FIFO. Durable Undo/Redo first settles the preceding live transaction.
A rejected prerequisite never falls through to an older group. Scratch editors
remain local and never borrow durable document history when empty.

While durable work waits or executes, new editing is blocked. Existing composition
can finish without forced unmarking. An accepted receipt can precede failed
refresh; observe session status before re-enabling controls. Unknown registrations
remain retained and block the integration until explicitly reconciled.

Presentation detach releases its bindings while the application collection retains
the session and recovery evidence. Close the session only at the domain ownership
boundary. See the [shared contract](native-editing-session-contract.md) and
[Durable Notes](../Examples/DurableNotes/README.md) for recovery and runtime checks.
