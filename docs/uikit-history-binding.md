<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# UIKit live editing and durable transactions

`NativeHistorySession.connectUIKit` connects `NativeHistoryTextView` controls to
the app-owned [native editing session](native-editing-session-contract.md).
`NativeHistoryTextView` overrides only its UndoManager getter. UIKit continues to
implement text input, selection, paste, composition, and fine-grained live Undo.
The adapter exposes the original native manager internally; its facade sends
live Undo/Redo to that manager and settled document Undo/Redo to the session.
No private callback inspection, typing-stack serialization, replacement text
editing, custom Undo key commands, or text-action overrides are installed.

```swift
binding = try session.connectUIKit(
    owner: self,
    editors: [titleEditor, bodyEditor],
    localEditors: [scratch],
    actionName: "Edit Note",
    captureDraft: {
        NativeDraftCapture(
            value: Note(title: $0.titleEditor.text, body: $0.bodyEditor.text),
            isComposing: $0.titleEditor.markedTextRange != nil
                || $0.bodyEditor.markedTextRange != nil)
    },
    draftDidChange: { $0.render($1) },
    statusDidChange: { controller, _ in controller.renderStatus() })
```

Callbacks receive a weak presentation owner. Do not capture it strongly.
The binding temporarily owns the text-view delegate role and restores the prior
weak delegate on disconnect. Use the binding callbacks for domain mapping and
presentation. Bind a control only once. Local editors remain ordinary UITextView
controls with independent native managers; empty local history never falls
through to document history. `binding.undoManager` follows the focused registered
control for toolbar actions and uses durable history when no live control owns
an editing transaction. Hosts resolve the durable action label; local names and
manager notifications come from UIKit's original manager.

## Transaction boundaries and outcomes

[ADR 0006](adr/0006-uikit-live-and-durable-undo.md) selects the persisted editing
transaction: editing end or movement to another bound editor, explicit commit,
an explicit semantic action, or explicit durable Undo. Pauses and punctuation do
not settle it. Native assistant Undo/Redo inside an open transaction remains
local, including Redo after text returns to the baseline. Exhausted native Undo
and equal values never imply acceptance or settlement.

`commit`, `requestCommit`, `applyDraft`, `undoDocument`, and `redoDocument` express
explicit boundaries. `applyDraft` settles prior editing before applying a new
host-proposed value. The session prepares Commands against the exact base and
opaque revision supplied by its lease. Explicit durable Undo settles and accepts
the draft before reversing its coarse group. Rejection or uncertainty stops that
invocation. Marked text prevents settlement; the binding never forces unmarking.

Known local registrations retire only after accepted finalization and successful
authoritative refresh, or after the host explicitly returns no Command because
it declares no semantic change. No-change is distinct from host rejection.
An accepted transaction whose authoritative refresh fails remains blocked and
does not reset live presentation or its local callbacks.

Active-session authoritative rejection preserves usable local Undo/Redo. New
captured values retain the exact rejected request and its evidence until the next
explicit boundary, which may prepare a new Command only after proved rejection.
Pending or ambiguous outcomes block local mutation and inverses without deleting
the stack or resigning first responder. Restored journals, including rejected
journals, require an explicit retry/discard decision before new editing; the
persisted rejected bit alone grants no editing permission.

The delegate barrier governs native user editing. Host programmatic operations
must use the binding/session APIs rather than mutating text controls during
admitted work. Selection and navigation remain UIKit-owned. The binding projects
availability notifications and refreshes the standard input assistant when
eligibility changes, without resigning focus; marked composition defers that
refresh. Installed assistant behavior requires runtime evidence.

Unexpected registrations on an editor or toolbar facade are forwarded to the
foundation manager's unexplained-registration path. They block admission and
complete closure and survive disconnect. The advanced explicit
`reconcileNativeRegistrations` certification releases them only after the host
identifies their authored work; it is not ordinary editing settlement.

## Ownership, closure, and compatibility

The app retains `NativeHistorySessions`; the session retains captured values,
prepared intent, journal and complete domain lease. The binding weakly references
controls and presentation. `close` captures and drains admitted binding work
before complete session closure. UIKit scene adapters provide platform
availability, protected-content visibility, and background execution budgets.
They do not recreate framework queues, draft journals, or recovery owners.

On genuine presentation disconnect, capture occurs synchronously while the owner
is available. Recognized local callbacks, delegates and control facades are
released even when persistence or lease closure remains blocked. The collection
retains the draft values and lease independently. A discarded presentation need
not retain ephemeral live micro-history. Unidentified callback graphs remain
recovery evidence until explicit certification.

The earlier sample's plain `{title, body}` Draft.json is not the typed journal
format. Opening refuses that incompatible evidence and preserves its original
bytes; retry/discard does not silently migrate or erase it. There is no automatic
empty-document substitution. iOS journal writes, host writes, the document
directory and current store sidecars retain complete file protection.

## Evidence and limits

The standalone iPadOS 26.5 probe recorded actual software-keyboard typing and
assistant routing through the original-manager facade. Its counter is not
durability or asynchronous acceptance evidence. The installed sample checks use
the public binding, independent durable host receipts and reopen, controlled
rejection/finalization failure, marked ranges, pending barriers, separate scenes,
and weak presentation teardown while a lease remains blocked. Programmatic
binding checks and interactive assistant observations are recorded separately.
Hardware shortcuts, physical IMEs/devices, and device-lock behavior remain
unqualified by simulator evidence.

Separate production-binding interaction on iPadOS 26.5 used actual software keys
to type `Alpha` and native assistant Undo/Redo with durable application count zero.
Explicit Commit raised the count to one; assistant durable Undo raised it to two
with empty body, and durable Redo raised it to three with `Alpha`. Keyboard/focus
remained intact and assistant eligibility refreshed. Source identity, sequence,
and authoritative Note.json evidence are retained locally under
`/Users/ctwelve/Developer/UndoKit/build/Diagnostics/UIKit-Binding-Live-26_5-2026-10-12`.
That interactive source checkpoint is distinct from later regression additions
and final installed Debug/Release reports.
