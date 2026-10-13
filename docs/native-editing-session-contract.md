<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Portable native editing session foundation

`NativeHistorySession<Lease>` coordinates typed provisional values, durable Commands
and complete document ownership. It is the foundation for the supported native
bindings, not qualification of stock text-control grouping or responder behavior.
The existing [native-routing contract](native-routing-contract.md) remains the
behavioral requirement for those bindings. This slice does not supersede it or
the accepted domain-ownership ADRs.

## App and host interface

Keep one app-owned `NativeHistorySessions<Lease>` collection. Construct the domain
lease without I/O, and open through the collection:

```swift
let sessions = NativeHistorySessions<NotesDocumentLease>()
let session = await sessions.open(
    documentURL: documentURL,
    mode: .existing,
    codec: HistoryCodec<Note>.json(),
    draftURL: documentURL.appendingPathComponent("Draft.json")
) {
    NotesDocumentLease(directory: documentURL)
}
```

Select `.create` explicitly for a new document. All recovery and reopening use
`.existing`; missing authoritative data is never replaced with an empty document.
Opening returns an owning session even on failure. Parallel opening calls await
the retained owner's acquisition. Canonical URL keys discard the incidental
file-versus-directory trailing-slash flag, including when directory creation changes
Foundation's appended URL. Inspect `status` rather than catching an error that
would lose partially acquired ownership.

| Interface | Responsibility |
| --- | --- |
| `NativeHistorySessions` | Own sessions by canonical document URL; return retained owners before invoking a factory; expose copied status entries; close all sessions for termination |
| `NativeHistoryLease` | Acquire host resources and history; read authoritative domain values and opaque revisions; prepare Commands against the supplied exact base; completely close history before releasing host ownership |
| `NativeHistorySession` | Persist captured draft values, admit one composite operation, reconcile exact prepared intent, publish status and retain blocked recovery |
| `NativeHistoryConnection` | Weak presentation attachment; capture/present values; disconnect and release callbacks; own no document resource |

The lease exposes `history`, `open`, `close`, `readDraft`, and `makeCommand`.
`readDraft` returns a value and an opaque domain revision. Equal values alone do
not establish the same revision. `makeCommand` prepares intent without I/O or
rebasing; nil means the host declares no semantic change. In that case the session
removes provisional evidence, restores the authoritative base to presentation,
and returns `.rejected` without delivering a Command.

[NotesDocumentLease](../Examples/DurableNotes/Sources/DurableNotesCore/NotesDocumentLease.swift)
illustrates this division. Its Note.json replacement contains effects and
host-authoritative receipts together. `applicationCount` supplies the revision
because Forward, Undo and Redo each change it, even when note values coincide.
The lease retains its physical store before scope opening, then closes engine,
store and domain lock in that order. Every partial acquisition survives until
complete closure succeeds.

## Operations and recovery

The session exposes `draft`, `undoManager`, `status`, one status callback, and
`submit`, `commit`, `undo`, `redo`, `retryDraft`, `discardDraft`, and `close`.
Ordinary editing code does not retain queues, invocation identities or engine
observers. Never bypass the session by concurrently submitting to its engine.
The raw engine's advanced FIFO interface remains unchanged.

`connect(owner:captureDraft:draftDidChange:statusDidChange:)` retains its presentation
owner weakly and passes that owner into callbacks. Do not capture that owner
strongly inside a callback. Only one live connection is permitted. Capture and
`updateDraft(_:isComposing:)` retain values rather than views. Commit and native
Undo capture synchronously; native Undo closes admission before starting its Task.
Further semantic submissions return busy instead of queuing arbitrary closures.

Undo of a provisional value is one composite operation: capture, prepare, persist
exact Command, await authoritative acceptance and finalization, refresh the domain
value, then reverse the newly accepted group. Rejection, uncertainty, conflicts or
failed refresh stop that same Undo; none may fall through to an older group.
A transaction can return `.accepted` while a subsequent presentation read fails:
the receipt still proves authoritative acceptance, but `status` stays blocked.
Do not resume editing from the transaction result alone.

The private typed journal binds scope, working identity, generation, codec
identity/configuration/version, base value/revision, proposed value/capture revision,
composition and any exact prepared Command. It is written before delivery. An
uncertain retry preserves all Command identities and bytes. Only a proved
rejection followed by a new explicit attempt receives a new identity. Equal text
is never acceptance evidence. Reopening a journal requires explicit retry or
discard; mismatch or unreadable evidence is preserved and cannot be discarded
through an incompatible session.

Writes are atomic. On iOS/iPadOS they additionally use `completeFileProtection`,
preserving the existing UIKit journal protection. Protection-related write failures
retain captured values and the lease and block complete closure. macOS uses the
platform's ordinary file permissions. Device-lock behavior needs native validation.

Close captures connected content, including marked text, drains admitted work,
preserves unsettled evidence, then awaits complete lease closure. Opening and
closure are serialized. Disconnect also captures a ready connected value before
releasing callbacks; during admitted work it preserves the already captured intent.
Failed persistence or closure stays discoverable in the collection. Explicit retry
can completely retire a failed persistence context and reopen existing history with
unchanged scope, generation and working identity. A fresh attachment epoch rejects
older availability callbacks. A retired session cannot reopen or remove its replacement.
The collection removes an entry only after complete closure and disconnection.

## Native binding boundary

This foundation's manager routes semantic Undo/Redo without executing superclass
native callbacks. Every superclass registration is currently unexplained: it
suspends semantic admission and Undo/Redo, blocks complete close, and retains the
registration objects through disconnection or unrelated acceptance. It does not
infer classification merely from a typed draft change. The advanced
`reconcileNativeRegistrations() async throws` action may release those callbacks only
after the host explicitly identifies their authored work and reconciles the values.
It works from blocked or suspended states and while a draft decision is pending.
It reacquires an already closed lease before capturing connected content, persists
that content before clearing, and executes no Command. It preserves exact prepared
intent and pending restore/discard choices; a conflicting captured value cannot
replace unsettled intent. New registrations arriving during awaited reacquisition
require another explicit reconciliation. Close drains this recovery work and
rechecks registrations before and after complete lease closure, retaining the owner
and callback objects if closure cannot certify their preservation.

The supported [UIKit binding](uikit-history-binding.md) supplies live original-manager
routing and coarse editing-transaction boundaries under ADR 0006. Supported AppKit
binding migration remains a separate slice. Bindings must classify the
stock controls' editing registrations, preserve unrelated native registrations,
project accepted host action names, and settle native typing coalescing and group
boundaries before capture. They must preserve marked-text composition and local
text-control priority, install and remove responders/delegates safely, and prove
actual native command routing, typing groups and deallocation. The portable
`commit` boundary is not proof of native typing-group settlement. A replacement
text-editing system or custom text mutations are outside this design.

The existing `NativeHistoryRouter` remains available for advanced integrations.
The published AppKit sample's `NotesSession` is retained during this foundation
slice; its controller migration and supported binding qualification are separate.
Swift public-session tests prove durable coordination and ownership, not installed
AppKit/UIKit acceptance, device-lock protection, or keyboard-shortcut behavior.
