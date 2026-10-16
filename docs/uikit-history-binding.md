<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# UIKit field bindings

A window or scene attaches to one shared `HistorySession` and binds
`NativeHistoryTextView` controls to typed `HistoryField<String>` declarations.
Use `attachment.bindUIKit(editors:localEditors:)` and provide its UndoManager
through the application's normal responder path. A field supplies authoritative
value/revision reads and maps captured intent to the registered typed Command handle.

UIKit keeps its proved original native manager for live text microhistory. The
binding preserves delegate restoration, selection/composition callbacks and keyboard
assistant refresh. The session owns transaction identity, ordering, journaling,
settlement, recovery and publication across attachments.

Typing followed by live Undo/Redo produces no durable deliveries. A complete
editing transaction settles at an explicit or supported focus boundary. Durable
Undo/Redo settles that transaction first; rejection never traverses an older group.
Local scratch editors retain their own history, including an empty stack.

Waiting or executing durable work blocks new editing and native Undo/Redo. Existing
marked composition may finish; adapters never force it to commit. Unknown callback
graphs are preserved and require explicit host reconciliation. Acceptance and
presentation readiness remain separate, so observe session status after completion.

Keep the binding and attachment in a stable scene owner. Disconnecting presentation
never closes a shared session. Explicit closure safeguards journals and delivered
work before UndoKit releases history storage and the domain lease.

See the [shared contract](native-editing-session-contract.md) and
[UIKit example](../Examples/DurableNotes/UIKit/README.md). Installed simulator checks
cover their reported runtime/configuration; physical keyboards, IMEs and devices
remain distinct evidence requirements.
