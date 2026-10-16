<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Shared History Session implementation evidence

This implements the accepted [session interface design](../session-interface-design.md)
and [ADR 0007](../adr/0007-shared-native-history-coordination.md). The implementation
starts at `e83021b` and is recorded in `7259323`, `0335a04`, `b09958b`,
`7f3637c`, `d75dfa4` and `e24a7fa`.
The latter commit is the source for the final package, native and consumer runs.
Production tree: `1f7ee1f564de35d27a4290d9dc9dea2120fcc251`; test tree:
`b3bd2a83cecbe376436078b6e04601223aeef7d0`; example tree:
`eccbbac03f361aed8e2fa921869255b79951d48a`. Subsequent changes only record evidence.

## Resulting interface

Ordinary callers open one retained session per working History Scope, bind typed
operation handles and attach presentations. The session owns history storage,
field journals, bounded admission, lifecycle and recovery. Native text bindings
produce the same typed Commands; the supplied UndoManager coordinates native
microhistory and durable Undo/Redo. Host adapters retain semantic validation,
atomic effects, receipts and resource policy.

`Interface/Application/`, `Interface/Hosting/` and `Interface/Advanced/` separate
supported access paths. Shared failure, identity and retention values remain at
the Interface root. The former generic native-session and typed-registration
submission paths were removed. Advanced capabilities share session admission;
the deliberate standalone transaction/storage layer remains available. No
compatibility adapters, old draft readers or migrations were added.

## Correctness and review

The initial fixes protect writer ownership during opening recovery and preserve
rejected recording-off inverse barriers. New regression coverage includes FIFO
reservation before encoding, frozen actor-local intent, cancellation, unresolved
followers, generation fencing, scope/store conflicts, host callback reentry,
shared native fields, composition and exact recovery evidence.

Separate standards and specification reviews found one module-placement issue
and two concurrency defects. All were fixed and the specification fixes were
re-reviewed: host translation now lives in HostAdaptation; discard holds the
existing reconciliation fence; an unprepared dependent remains cancellable while
native settlement waits. Additional coverage verifies that closure during core
reconciliation preserves its accepted receipt and skips retired presentation
refresh. No review findings remain open.

Installed AppKit testing also exposed a native notification-ordering issue:
settlement now rereads the actual marked range before admitting work. All four
sample harnesses now distinguish a lost host reply from an invalidated storage
context. Failed-save recovery requires safe close and existing-only reopen;
checks demand the original complete group, byte-identical receipts and zero new
host delivery callbacks.

Simulator checks additionally corrected example lifecycle sequencing: publish
negative availability before awaiting closure, retain failed storage acquisition
before attaching editors, resolve a rejected draft explicitly before unrelated
Commands, and wait for presentation attachment after asynchronous reopening.
These changes preserve the framework admission and evidence rules. Native
teardown also exposed binding retention when a journal write failed. Exact field
capture now precedes persistence: known presentation callbacks can retire while
the session retains the captured draft for repaired closure and reopening.
Unexplained callbacks remain protected in the session facade; a conflicting
prepared intent still refuses detachment. Restored rejected drafts now remain
decision-gated: only a rejection from the current attached transaction permits
continued native editing. Four regressions cover restored, live, detached and
late rejection without adding persisted compatibility state.

## Validation

Environment: Xcode 27.0 (27A266a), Apple Swift 6.4, Swift 6 complete concurrency,
macOS 27.0.1 (26A434), arm64. Simulator checks use iPadOS 26.5 (23F77), arm64.

| Check | Result |
| --- | --- |
| Package Debug, including opt-in 100-group workload | 158 passed, zero skipped or failed |
| Package Release, including opt-in 100-group workload | 146 passed, zero skipped or failed |
| Maintenance checks | Passed; 155 obsolete exemptions removed, zero new exemptions |
| Maintenance checker fixtures | Seven expected outcomes passed |
| Independent package/native consumers, macOS + simulator, Debug + Release | Passed |
| Installed AppKit, Debug + Release | Passed |
| Installed SwiftUI/AppKit, Debug + Release | Passed |
| Installed UIKit, Debug + Release | Passed |
| Installed SwiftUI/UIKit, Debug + Release | Passed |

Final package logs: `/private/tmp/undokit-complete-debug.log` and
`/private/tmp/undokit-complete-release.log`. Native runner evidence is retained
under `~/Library/Developer/Xcode/DerivedData/UndoKit/Evidence/`:

- AppKit Debug: `DurableNotes/20261016T004045Z-798f9b`.
- AppKit Release: `DurableNotes/20261016T004055Z-83edbc`.
- SwiftUI/AppKit Debug: `DurableNotesSwiftUI/20261016T004114Z-0e0ba1`.
- SwiftUI/AppKit Release: `DurableNotesSwiftUI/20261016T004126Z-f9dd44`.
- UIKit Debug: `UIKitNotes/20261016T003845Z-164ff2`.
- UIKit Release: `UIKitNotes/20261016T004020Z-bc535d`.
- SwiftUI/UIKit Debug: `DurableNotesSwiftUIiOS/20261016T003935Z-a19122`.
- SwiftUI/UIKit Release: `DurableNotesSwiftUIiOS/20261016T004116Z-419099`.

Final consumer logs are `/private/tmp/undokit-complete-consumers-{macos,ios}-{debug,release}.log`.
Each route prints its receipt/readback evidence before temporary fixture cleanup.

The runner reports include loaded library paths, runtime identity and observations.
Debug-only failure injection is intentionally absent from Release. Consumer checks
verify both source-package and native-framework routes, atomic two-member groups,
three deliveries/six member effects/three receipts, Undo/Redo, reopen, bundled
model/privacy resources and one shared runtime type identity.

## Limits

Native checks use programmatic platform input and responder actions. Physical
keyboard/IME testing, physical devices, floor-OS and Intel runtime qualification,
forced termination and distribution signing remain separate release gates. A
universal build is not Intel runtime evidence. The opt-in workload is the bounded
100-group regression, not the separate production-scale campaign. Folio and
KitchenMemory adoption is intentionally deferred until this interface stabilizes.
