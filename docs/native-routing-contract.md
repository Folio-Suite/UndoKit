<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Native routing contract

Native routing belongs to `HistoryAttachment` and the shared session's field
coordinator. The former independent router and generic whole-draft session are
superseded by [ADR 0007](adr/0007-shared-native-history-coordination.md).

The attachment supplies the application's UndoManager. Native live registrations
remain platform microhistory; they are not serialized as semantic Commands.
AppKit recognizes exact editor/text-storage targets and forwards them to its live
manager. UIKit uses its original live manager. Unknown callbacks remain retained
and block the affected integration until explicit reconciliation.

Only one live transaction participates in a scope. Native Undo at its baseline
cannot fall through into durable history, and local scratch contexts never borrow
another scope's history. Semantic submission, field settlement and durable inverses
share the transaction FIFO. A rejected prerequisite stops the dependent invocation.

See [session lifetime and recovery](native-editing-session-contract.md),
[AppKit](appkit-history-binding.md) and [UIKit](uikit-history-binding.md) for the
current binding contracts and evidence boundaries.
