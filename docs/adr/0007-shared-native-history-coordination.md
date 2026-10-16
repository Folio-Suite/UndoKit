<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Shared native coordination for application History

Accepted direction on 2026-10-15. One shared module owns live/durable editing
coordination, with small platform adapters for native behavior. This concentrates
admission, settlement and recovery knowledge and gives callers a consistent
ordinary integration path. The primary interface supports general application
Commands, including renaming, reordering and inspector changes; native text
bindings are optional conveniences.

One History Session owns each open History Scope. Multiple windows or editing
contexts attach to that session and share ordering, Undo/Redo Availability and
recovery ownership; creating or rebuilding a presentation does not create another
session. Typed semantic Commands are the ordinary editing interface. Native text
adapters produce those same Commands at settlement. Hosts define operations once;
editing call sites submit typed values without handling opaque encodings or
requiring whole-document snapshots. State-based conveniences remain possible.

Use typed operation handles bound once to their History Session and registered
host adapter. Ordinary call sites submit semantic values through those handles;
they do not select codecs, assemble opaque Commands or maintain family routers.
This permits independently organized operation families without requiring one
scope-wide Command enum. Focused advanced capabilities share the same owner and
cannot bypass native admission. This revises the ordinary-entry-point guidance
in [ADR 0001](0001-transaction-module-ownership.md), while preserving its narrow
transaction capability for lower-level integration and the host ownership and
isolation guarantees of [ADR 0003](0003-host-adaptation-module-ownership.md).

UndoKit owns a bounded, ordered queue for ordinary typed Commands. Callers do
not maintain submission chains or retry merely because the session is busy.
Native editing and Undo/Redo are blocked during durable work. Cancellation can
remove work that is still queued. When an earlier Command becomes uncertain,
still-queued requests complete explicitly as unexecuted with recovery required.
They are not replayed automatically after recovery; callers must submit fresh
intent. Preserve exact recovery evidence for work that may already have executed.
The existing durable preparation and authoritative-outcome guarantees continue
to govern prepared and delivered work.

The ordinary native integration supplies UndoKit's UndoManager as the app's
document, window or responder manager. Native menus and controls use that manager
while the framework coordinates asynchronous work. Arbitrary existing callbacks
cannot be converted into durable Commands automatically. Preserve unexplained
registrations and block the affected integration until explicitly reconciled;
support for keeping an arbitrary existing manager instance would require a
separately proven advanced adapter.

Preserve the live/durable behavior established by
[ADR 0006](0006-uikit-live-and-durable-undo.md). An isolated native-method AppKit
experiment on macOS 27.0.1 passed 17 checks: when the window exposes the facade,
the text view's original manager can resolve to that same facade. A delegate can
supply a separate live manager, but native text registrations still enter the
facade and need AppKit forwarding. This supports a small platform adapter and
does not justify replacing the existing dedicated live stack. The experiment
does not qualify real typing, composition, durable acceptance or other OS
versions. Platform differences survive where native evidence requires them,
rather than cause duplicated coordination logic.

This is greenfield work. The maintainer waives backward compatibility for public
declarations and pre-release persisted formats, including draft journals. Do not
add legacy adapters, older-format readers or migration paths for this refactor;
Folio and KitchenMemory will conform after the design stabilizes. Current-format
durability and recovery remain required. Retain deliberate lower-level integration
access. Organize `Interface/` by supported access path, with genuinely shared
contracts at its root. The ordinary module owns framework storage, journals,
queueing and lifecycle coordination; host adapters retain domain ownership,
atomic outcome evidence and application policy. Concrete declaration spelling
and internal mechanics are implementation choices, constrained by this decision
and the [session interface design](../session-interface-design.md).

This records the accepted architecture, not a completed implementation.
Host-authoritative outcomes, actor isolation and the existing durable acceptance
and recovery guarantees remain required.
