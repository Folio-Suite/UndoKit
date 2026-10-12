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
26.5 probe proved that system keyboard Undo/Redo reaches a supplied manager,
but typing did not register in that manager: a getter-only replacement is
insufficient to claim live editing Undo. The supported binding must establish
how local callbacks and durable groups coexist, retire only known local work
after authoritative acceptance, and state any remaining native limitations.
No idle-timer approximation or private typing-stack serialization is adopted.
