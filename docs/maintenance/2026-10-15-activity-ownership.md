<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# History activity ownership

Follow-through for issue #59 and ADR 0007. Public interfaces, persisted formats,
products and host-authoritative outcome responsibilities remain unchanged.

`HistoryStoreActivity` owns the physical-store maintenance fence and the registry
of admitted scope lifetimes. Maintenance stops new admission and awaits completion
notifications for every previously admitted lifetime, including opening recovery,
Commands awaiting encoding, native settlement, authoritative reads and publication.
It does not poll suspended tasks. Registering an idle waiter and checking activity
are one MainActor turn. Cancellation removes only that waiter's continuation;
completion and cancellation cannot resume it twice. Cancelling maintenance releases
its store fence while leaving the admitted scope work intact.

`HistoryScopeActivity` owns opening/reconciliation exclusion and monotonic closing
and closed state. It consults the physical-store fence while preserving independent
scope concurrency. Each asynchronous operation owns an idempotent completion token;
completion releases exclusion and notifies eligible scope/store idle waiters.
Core reconciliation and its authoritative presentation refresh share one lifetime.
Native discard uses that same owner, including thrown reads and cancellation.
Closure waits for active work and never revives a retiring presentation.

`HistoryTransactionCoordinator` retains the only Command FIFO. Every reservation
owns a completion token from admission through its terminal result; late encoding,
cancellation and closure callbacks cannot finish it twice. The drain owns a separate
lifetime through prerequisite settlement and publication, since a cancelled,
unprepared dependent request can finish before its native prerequisite. Maintenance
drains reservations already admitted; closure rejects waiting reservations and
waits for delivered work to be safeguarded. Completion notification replaces caller
managed closure continuations. Callback TaskLocal fencing is assembled in one helper
and preserves nested-store and same-scope reentry rejection.

Retained-history mutation and recovery-plan admission consult the scope owner's
idle check. They cannot change protected evidence during an authoritative discard
read, opening, reconciliation or store maintenance. Storage checks, authoritative
receipts, original-data preservation and recovery protection remain with their
existing owners.

## Validation

The focused public regression first demonstrated checkpoint admission during a
suspended native discard read, then passed after admission used the shared idle
check. Additional deterministic host gates cover maintenance during suspended
opening, concurrent scopes and already admitted Commands, maintenance cancellation,
cancelled reconciliation, and cancelled discard with a throwing authoritative read.
Assertions use public history/transaction behavior, persisted host state and
host-authoritative receipts.

Implementation base: `574d923952becf28d4866e018bd65c22600e529a`.
`ruby scripts/check-toolchain.rb` passed with Xcode 27.0 (27A266a), Apple Swift
6.4, arm64 macOS. Using the default locked shared DerivedData package cache:

```sh
scripts/test-package.sh --filter 'History(ActivityAdmission|OpeningActivity|NativeDiscard|StoreLifecycle|StoreMaintenance|ApplicationSession)Tests|UndoKitTests.UndoKitTests'
scripts/test-package.sh -c release --filter 'History(ActivityAdmission|OpeningActivity|NativeDiscard|StoreLifecycle|StoreMaintenance|ApplicationSession)Tests|UndoKitTests.UndoKitTests'
```

Focused results: Debug 52 tests and Release 50 tests, zero failures. A final
review then restored the synchronous transaction/store closing guards before
reconciliation presentation refresh; the exact integrated-head suites validate
that final guard restoration.
The original checkpoint/discard regression was run red before the admission fix
(two failed assertions), then green. `git diff --check` passed. The integrating
change owns the full package suites and native consumer qualification; no native
producer, simulator or device qualification is claimed by these package checks.
