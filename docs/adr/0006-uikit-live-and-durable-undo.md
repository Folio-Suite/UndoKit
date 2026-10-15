<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Separate UIKit live editing Undo from durable groups

Accepted by the maintainer on 2026-10-12. UIKit durable editors use an editing
transaction as the persisted Undo Group: editing end or a move to another bound
editor, an explicit commit or semantic action, or semantic Undo settles the
transaction; pauses and punctuation alone do not divide it. Native controls
should retain their finer live-editing Undo for immediate use where supported,
without requiring those micro-edits to be serialized or recreated after reopen.

The framework owns binding lifecycle, draft journaling, admission, settlement,
recovery and cleanup; hosts supply domain meaning, authoritative outcomes,
draft mapping and application presentation policy. Marked-text composition
prevents settlement and must be preserved, never forcibly committed. A durable
Undo of an unsettled draft accepts that draft before reversing its group;
rejection or uncertainty stops that invocation.

This revises the UIKit persisted typing-coalescing requirement in the
[native-routing contract](../native-routing-contract.md), while preserving
native editing, selection, composition and native command presentation. The
26.5 probe proved that software-keyboard assistant Undo/Redo reaches a supplied
manager, but typing did not register directly in that replacement manager.
A refined getter-only adapter exposes the control's original manager and returns
a facade that routes open-transaction Undo/Redo to it. Real software-keyboard
typing and assistant Undo/Redo reversed and reapplied `Alpha`, including local
Redo after returning to the baseline. Explicit rejection preserved that history;
explicit acceptance cleared only the known original stack with focus intact,
then assistant Undo reached a seeded counter. Manager exhaustion and value
equality were never transaction boundaries.

That probe used source SHA256
`d406f7ab97d726d92f5fc4142d2fd527812c0f798edd1a1b494d027539fad85e`,
runtime run `71C336EF-4B86-452C-931F-67FBF4265563`, and the standalone
`NativeRoutingLive26` app on iPadOS 26.5. Local source/runtime evidence is retained
at `/Users/ctwelve/Developer/UndoKit/build/Diagnostics/UIKit-Live-Undo-26_5-2026-10-12`.
The synchronous counter establishes routing, not persistence, asynchronous
acceptance, hardware shortcuts, or physical IME qualification.
The supported binding must establish
how local callbacks and durable groups coexist, retire only known local work
after authoritative acceptance, and state any remaining native limitations.
No idle-timer approximation or private typing-stack serialization is adopted.

## AppKit extension

The maintainer explicitly authorized the same live/durable distinction for
AppKit in [issue #40](https://github.com/Folio-Suite/UndoKit/issues/40).
Standard `NSTextView` keeps fine native Undo/Redo, including Redo at the original
baseline. An explicit commit, actual editing end/focus transfer, or host semantic
action settles one coarse durable editing transaction; native event-group closure,
pauses, punctuation, stack exhaustion and equal draft values do not settle it.
Explicit durable Undo first accepts that transaction and then reverses its group;
rejection, uncertainty or failed authoritative refresh stops the invocation.

The supported getter-only `NativeHistoryAppKitTextView` exposes an Undo facade.
AppKit registers text operations directly through that manager, so the binding
uses a dedicated live manager rather than UIKit's original-manager routing.
Only registrations targeting the exact bound editor or its public `textStorage`
are recognized live work. Other registrations enter the shared session's retained
evidence barrier; ordinary acceptance or disconnection never clears them.
Hosts must not register unrelated operations against the bound editor/text storage.
The adapter supplies standard `undo:`/`redo:` responder actions and validation;
it does not replace native input or install keyboard shortcuts.

[AppKit binding guidance](../appkit-history-binding.md) records lifecycle,
recovery and the separate method/native/human-interaction evidence boundaries.
This extension adds no persisted schema, private API or typing-stack serialization.
