# Connect your own model

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Replace the example's domain host while keeping session and presentation wiring.

The platform guides use `DurableNotesCore` so the storage and recovery contract is
runnable rather than hidden behind placeholders. Your app supplies the equivalent
of its `NoteChange`, `DurableNotesHost` and `NotesDocumentLease`. You do not need to
adopt its JSON datastore or expose UndoKit's storage internals.

## Define one semantic operation

A Command describes **intent**, such as replacing a title only if it still has
an expected value. An effect records enough information to undo and redo an
accepted change. They can be the same Swift type, as in Durable Notes, or different
types. Keep them transferable when using ``HistoryOperation``.

Register each operation once with a stable family, versioned codecs, actual host
handler and canonical Intent Fingerprint. This excerpt is the sample's declaration,
created after opening its domain host:

```swift
import Foundation
import DurableNotesCore
import UndoKit

func noteOperation<Handler: HistoryOperationHandler>(
    handler: Handler
) throws -> HistoryOperation<NoteChange>
where Handler.Command == NoteChange, Handler.Effect == NoteChange {
    try HistoryOperation(
        operation: "durable-notes.change",
        commandCodec: .json(), effectCodec: .json(), handler: handler,
        fingerprint: { changes in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(changes)
        })
}
```

Keep this declaration and its handler for the session lifetime. Recreating a
lookalike operation for each button press does not preserve registration identity.
Get `session.commands(for: operation)` once, then pass that typed handle to your
editing code. Fingerprints represent canonical intent; they are not a fresh UUID
or a claim that a previous request succeeded.

## Apply effects and receipts together

Implement ``HistoryOperationHandler`` on an actor, or
``MainActorHistoryOperationHandler`` when the domain belongs on MainActor. Both
provide `apply`, `undo`, `redo` and authoritative `outcome(for:)` lookup.

For each delivered group:

1. Look up its complete token in your durable receipt store. If it already has an
   outcome, return that outcome without applying effects again.
2. Validate **all** members against the current domain state.
3. Commit the group's complete effect and token-bound receipt atomically in your
   own datastore. Never accept a partial group.
4. Return the corresponding typed effects, preserving each delivered member ID.

Undo and Redo are new deliveries with their own tokens. Their effects and receipts
follow the same atomicity rule. For a mixed-family atomic group, provide the paired
atomic executor/outcome callbacks in ``HistorySessionSetup``; independent family
callbacks cannot establish a shared atomic commit.

The sample commits its note and receipts in one atomic JSON-file replacement
under an exclusive writer lock. A Core Data host would normally persist them in
one coordinated domain transaction instead. This is your application's transaction,
separate from UndoKit's history finalization.

If a write might have succeeded, return `.unresolved` until authoritative lookup
can prove its outcome. A timeout or thrown write is not proof of rejection.
The sample reloads its file before answering recovery lookup. It can treat a
missing token in an intact file as rejection only because its single-writer,
atomic-file contract proves that no corresponding effect committed.

## Give the session a domain lease

A ``HistoryHostLease`` acquires and releases only your domain resources. Its
initializer must not acquire them: the application collection retains ownership
**before** calling `open`. Use the asynchronous configure closure when operation
setup needs the opened host, as shown in <doc:FirstUndoGroup>.

The returned ``HistorySessionSetup`` names the history URL, stable scope and
working identity and registered operations. UndoKit opens/closes its own storage
and journals, then releases the domain lease after successful closure. A failed
close keeps the responsible owner. Reuse the same lease when reopening an already
live document; prefer sharing the document wrapper rather than opening it twice.

## Map native fields

A ``HistoryField`` declares a stable field ID and mapping ID, codec, typed handle,
authoritative value/revision read and a mapping from the base snapshot plus
proposed value to Commands. Return an empty array for a known no-op. Equal visible
values are not enough to establish that the authoritative revision is unchanged.

The sample uses its application counter as the revision because all its accepted
changes pass through one writer. Use your domain's real revision scheme when
other writers or external edits are possible. Bind this field through the native
platform adapters; they handle draft capture, settlement and refresh.

## Keep ordinary call sites small

A rename button should submit a typed rename. It should not assemble payloads,
manage a retry identity, take a whole-document snapshot or open its own history
store. Use ``HistoryStore``/``HistoryEngine`` directly only for a deliberately
lower-level integration; do not open a competing owner beneath a shared session.

## Source to study

- [Domain model and Commands](https://github.com/Folio-Suite/UndoKit/blob/main/Examples/DurableNotes/Sources/DurableNotesCore/Note.swift)
- [Atomic host and receipts](https://github.com/Folio-Suite/UndoKit/blob/main/Examples/DurableNotes/Sources/DurableNotesCore/DurableNotesHost.swift)
- [Lease, operation registration and field mapping](https://github.com/Folio-Suite/UndoKit/blob/main/Examples/DurableNotes/Sources/DurableNotesCore/NotesDocumentLease.swift)

## Topics

- ``HistoryOperation``
- ``HistoryOperationHandler``
- ``MainActorHistoryOperationHandler``
- ``HistoryHostLease``
- ``HistorySessionSetup``
- ``HistoryField``
- <doc:RecoveryAndStorage>
