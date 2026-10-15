<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# AppKit editing transactions

`NativeHistoryAppKitBinding<Lease>` connects standard text editing to the shared
[native session](native-editing-session-contract.md). Keep an app-owned session
collection, a domain-only complete lease, and one binding per presentation. The
host owns Note meaning, validation, receipts, scope and presentation policy.
UndoKit owns admission, draft capture/journaling, settlement, asynchronous
barriers, live callback cleanup and exact recovery. The accepted AppKit extension
of [ADR 0006](adr/0006-uikit-live-and-durable-undo.md) defines coarse durable groups.

```swift
let binding = try session.connectAppKit(
    owner: controller,
    editors: [controller.titleEditor, controller.bodyEditor],
    localEditors: [controller.scratchEditor],
    actionName: "Edit Note",
    captureDraft: { owner in
        NativeDraftCapture(
            value: Note(title: owner.titleEditor.string, body: owner.bodyEditor.string),
            isComposing: owner.titleEditor.hasMarkedText() || owner.bodyEditor.hasMarkedText())
    },
    draftDidChange: { owner, note in
        owner.titleEditor.string = note.title
        owner.bodyEditor.string = note.body
    },
    statusDidChange: { owner, status in owner.show(status) }
)
```

Use `NativeHistoryAppKitTextView` for every bound/local editor, retain the binding,
and pass the owner into callbacks instead of capturing it strongly. The adapter
keeps native text input, selection, layout, scrolling and composition. Its
getter-only manager facade supplies the standard `undo:`/`redo:` responder actions
and validates them against current binding availability. Use ordinary Edit menu
items and Cmd-Z/Shift-Cmd-Z. The sample's window provides the same thin fallback
when the first responder is outside an editor. No custom shortcut interception
or replacement text-input system is needed. The binding leaves host delegates
installed; its text-view admission override gates both single and multiple ranges.

While a live editing transaction exists, native Undo/Redo stays on its known
native stack, even after Undo returns the text to its baseline or exhausts that
stack. A focused local editor always consumes its own Undo context, including
when empty. Explicit `commit()` or `settleEditing()`, actual editing end/focus
transfer, and `applyDraft(_:)` settle coarse transactions. Native event-loop group
closure does not persist each key. `undoDocument()` and `redoDocument()` explicitly
settle live intent before a durable inverse; a rejected or unresolved settlement
never falls through to an older group. `hasLiveTransaction`, `lastResult`,
`status`, `permitsEditing` and `undoManager` provide presentation information.
Always inspect status after a result: acceptance can precede a failed authoritative
refresh, leaving editing blocked.

Marked text prevents live/durable Undo and settlement. A deferred focus boundary
resumes after composition finishes; the binding never forcibly unmarks text.
`isAvailable = false` adds a host availability barrier without releasing document
ownership. Pending, uncertain, failed-refresh and restored-draft states deny native
text admission and asynchronous inverses. Hosts may reflect `permitsEditing` in
controls and buttons, while preserving active marked text. Programmatic model or
text-storage mutations are host operations: submit through `applyDraft` or the
session rather than bypassing admission.

AppKit's native text-storage registrations enter a dedicated live manager.
Only exact bound editor/text-storage targets are recognized; hosts must not put
unrelated work against those objects. Accepted settlement plus successful refresh
retires that known live work and breaks native coalescing. Rejection preserves it.
Unknown targets go to the shared session manager, suspend editing and retain their
callback graph through disconnection and failed closure. Identify authored work
and reconcile its values before explicitly calling
`session.reconcileNativeRegistrations()`. That operation clears evidence without
executing it and preserves prepared intent and pending draft decisions.

`retryDraft()` reuses exact prepared intent after uncertainty; it consults receipts
without duplicating an accepted effect. `discardDraft()` is available only where
history can prove discarding is safe. Reopening any retained draft requires an
explicit retry/discard decision. Existing-only reopen refuses unavailable host or
history data without creating replacement storage. Return the original storage
before reacquisition. In Debug, `demonstrateFinalizationFailure()` exercises the
production accepted-effect/failed-finalization path; it is absent in Release.

Call `waitForOperations()` when draining presentation commands. `close()` captures
content, blocks availability and awaits complete session closure. Check `status`;
a failed close remains retained in the app collection. For in-place reopen, keep
the connection attached while calling `sessions.reopen(session)`, then disconnect
and reconnect presentation. A closed disconnected owner is deliberately retired
and cannot reacquire in place. `disconnect()` journals current content, releases
known callback stacks and all weak presentation callbacks, and cancels no admitted
host delivery. A retained blocked session continues owning recovery resources.
Live microhistory is presentation-local and is not recreated after teardown.
Ordinary SwiftUI value reconstruction should retain the same binding and editors;
managed SwiftUI hosting has its own lifecycle contract.

## Evidence and limits

The [runnable host](../Examples/DurableNotes/README.md) uses the shared session and
`NotesDocumentLease`, with no controller operation queue or parallel history state
machine. Its runner records source/configuration/runtime identity and independent
host Note/receipt values. `NotesAppKitBindingTests` covers live baseline Redo,
rejection/no fallback, failed authoritative refresh/exact retry, unknown callback
retention, unavailable storage without replacement, weak owner teardown and an
explicit restored-draft decision. Installed native checks exercise actual text
controls, responder actions, marked ranges, independent windows, delayed outcomes,
Debug finalization recovery and complete close/reopen. These programmatic checks
are distinct from actual keyboard/menu review. Current-runtime interaction evidence
and any failures are retained with the task; no floor-OS, Intel hardware, human IME,
forced termination or binary distribution qualification follows from compilation.
