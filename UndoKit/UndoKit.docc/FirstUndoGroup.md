# First Undo Group and native editing

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Keep authoritative effects in the host and await finalized completion.

## Establish a stable scope

Use ``HistoryStore`` when a document owns multiple independent History Scopes,
or ``HistoryEngine`` for a one-store/one-scope convenience. Persist stable host
working/scope identities. Open known history with `.existing`; `.create` is only
for genuinely new history. A view reconstruction does not create another writer.

Implement ``HistoryHost`` for opaque payloads, or register typed handlers using
``HistoryOperationRegistration``. The host filters known no-ops, assigns a stable
Command identity and canonical intent fingerprint, then supplies every member of
a semantic group. Typed handlers and codecs are registered from application code
again after reopen; callbacks are not serialized into history.

The independent compiled consumer example submits two members setting `alpha`
and `alpha-beta`. Its host atomically persists the full state and token-bound
accepted effects/receipt before reporting acceptance. Undo restores the empty
baseline; Redo restores `alpha-beta`. Three accepted deliveries produce three
receipts and six applied members. The reopened host verifies content and receipts
independently of the engine's availability flags.

The host must apply the complete ordered delivery atomically, or establish that
none took effect. A possible effect followed by uncertainty is unresolved;
absence from a transient receipt map is not proof of rejection.

## Observe completion

```swift
import UndoKit

@MainActor
func submitChange(
    _ command: HistoryCommand,
    using history: any HistoryTransactions
) async -> HistoryResult {
    await history.submit(command)
}
```

An accepted result follows authoritative domain acceptance and history
finalization. Queue admission and native Undo registration are not durable
receipts. Rejection establishes no effect; a failure's stage and disposition
control whether editing or inverses can continue. Do not change identity to
bypass a possibly delivered Command.

## Use genuine native editing

``NativeHistorySession`` retains document editing/recovery coordination behind
an app-owned complete domain lease. Native AppKit/UIKit bindings keep real text
control microhistory in the platform manager. Explicit editing boundaries create
durable Undo Groups; UndoKit does not serialize native typing registrations.

Typing followed by native Undo to baseline and Redo should produce no durable
delivery. Explicit Commit produces one group. Durable Undo/Redo then each produce
one authoritative host receipt. Local scratch history keeps responder priority
and never falls through to another document group. Marked composition must reach
a supported settlement boundary before durable delivery.

For SwiftUI, keep editor, binding and session in a stable document/scene owner.
Present the framework-owned native-backed editor and use `nativeHistory(binding)`
for the explicit `nativeHistoryUndoManager` environment; the SDK's built-in
undoManager environment is read-only. Rebuilding a value view must not replace the
native manager or duplicate the document writer. Refresh command eligibility from
facade checkpoints and native focus changes, rather than durable status alone.

## Topics

- ``HistoryTransactions``
- ``HistoryHost``
- ``HistoryCommand``
- ``HistoryResult``
- ``NativeHistorySession``
- <doc:RecoveryAndStorage>
