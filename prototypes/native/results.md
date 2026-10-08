<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# #48 native proof results

## Automated run

- Latest runner source base: `8fe3d41fecfe4f6a21ff22ce3eb9d832f2eadb71`
  plus the `run.rb` hardening in [evidence.md](evidence.md). The earlier native
  UI observations retain their separate pre-commit source identity.
- Host: macOS 27.0, arm64, Apple Swift 6.4, Swift 6 strict-concurrency mode,
  warnings treated as errors, Debug build. The shell sandbox did not expose
  the CPU model, so this report does not identify it from the tool output.
- Command: `ruby UndoKit/prototypes/native/run.rb` from the repository root.
  Limits: 180 seconds, 2 GiB sampled child-process memory, 12 GiB scratch disk,
  and 20 GiB free-space floor.
- Result: build succeeded; four `NativeProofCore` behavioral tests passed.
  The tests cover both Undo and Redo after serialization/rebuild, one pending
  invocation, rejection, unresolved state, interference, Redo abandonment and
  monotonic availability versions across pending/interference transitions.
- App: system temporary directory `FolioNativeUndoProof.app`. The bundle is a
  disposable host, and the fixture is JSON snapshots in the scratch directory
  shown in the app log. No production document or UndoKit store is used.
- Runner cleanup: injected `ps`, `du` and `df` watcher failures each wrote a
  preserved JSON report, signaled the child process group, reaped the root and
  left the recorded child PID absent. Limit overrides above 600 seconds, 2 GiB
  memory or 12 GiB disk, or below a 20 GiB free-space floor, are rejected.

## Native AppKit observations

The coordinator's accessibility-driven run on the prior app build observed
document typing, keyboard and menu Undo/Redo, local text priority, two documents,
an A clone, pending barriers, focus retention, rejection, unresolved state,
interference and clean relaunch with both directions. See [evidence.md](evidence.md)
for the actual sequence and build identity. The final rebuild only adds a
marked-composition guard; that scenario has no native observation.

## Open design gaps

1. The 0.55-second host idle boundary and `breakUndoCoalescing()` do not prove
   exact correspondence between AppKit typing groups and semantic Undo Groups.
   Marked text is deferred, but composition behavior still needs a native run.
2. The routing adapter bypasses the editor's provisional native undo stack.
   Its real `NSUndoManager` Undo/Redo notifications do not align with semantic
   finalization. The app logs native typing-manager notifications so that the
   mismatch is observable. A production bridge must settle this mechanism.
3. Snapshot JSON is a relaunch fixture. It does not prove #47 transaction
   recovery, #49 lifecycle, or #50 retained branch storage. Abandoned ordinary
   Redo is truncated in this routing projection.
4. `Resolve` represents a simulated authoritative no-effect host response.
   It is not evidence of a real recovered receipt.
5. The unknown-registration button explicitly flags its own inert registration.
   Detection of an independent third-party registration and safe native-stack
   reconciliation remain unproved.
6. Action names and ordinary Undo/Redo labels are hardcoded in English. Locale
   switching and localized fallback naming were not exercised.
7. A deliberately unknown registration on `NSDocument.undoManager` marked the
   document edited while the proof-owned accepted-change balance remained zero.
   Reconciliation preserved AppKit's dirty signal, as it should for potentially
   meaningful unowned work. The clean no-work reattachment case stayed clean.
