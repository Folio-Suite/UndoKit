<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# SwiftUI editor presentation ownership

`NativeHistoryPresentationOwnership` in `Modules/NativeEditing` is the shared
policy beneath the public SwiftUI editor wrappers. It keeps the current host and
waiting hosts weakly, ignores repeated attachment, removes detached waiters,
and promotes the first
surviving waiter after the current host releases the editor. Dead weak entries
are pruned before promotion.

The AppKit and UIKit wrappers retain their weak editor-key registries and native
container implementations. Each adapter checks that the editor has no existing
superview before a new presentation may mount it, owns native mounting and
visibility behavior, and reports an unavailable presentation when another
parent already owns the editor. The shared policy never reparents an editor
from an unrelated native hierarchy.

Presentation teardown only releases the SwiftUI host. The stable document
owner continues to own the editor and History Session, so pending or rejected
draft recovery remains attached to that session. UIKit visibility callbacks
still require the callback's host to be current before changing temporary
detachment state; stale hosts cannot authorize a replacement presentation.

Coverage uses real SwiftUI/native hosts and public session/readback interfaces.
The AppKit overlap test reconstructs the same representable repeatedly, removes
one waiter, observes its hosting view's weak release, promotes two surviving
waiters in order, then refuses an unrelated native parent. The installed UIKit
probe uses standalone hosting-controller roots and exercises the same ownership
pattern alongside the existing weak editor, owner, binding and hosting-controller
release observation. Both installed
consumers rebuild the editor while a draft is rejected and while delivery is
pending, preserving draft callbacks and input barriers. Existing recovery,
authoritative refresh and late-result fencing coverage remains intact.

The new AppKit test initially crashed at `objc_release` during asynchronous
teardown. Its programmatic ARC-owned windows were closed with AppKit's default
automatic release enabled. Setting `isReleasedWhenClosed = false`, as in the
existing disposal test, made the focused public test pass without product
changes. The retained original crash is
`~/Library/Logs/DiagnosticReports/xctest-2026-10-15-200139.ips`.

The UIKit overlap probe initially hid a row in the main SwiftUI `Form`. The
native container remained mounted after a bounded 30-second observation, so
that action did not exercise dismantling. SwiftUI may cache Form rows after
disappearance. The final probe disposes standalone `UIHostingController` roots
to test actual current/waiter removal, preserving the existing platform visibility
callbacks. Form disappearance is not asserted to imply container destruction.

Validation uses Xcode 27.0 (27A266a), Swift 6.4, the shared DerivedData root,
macOS 27.0.1 (26A434) on arm64, and iPadOS 26.5 on the supplied iPad Pro
13-inch (M5) simulator `241ED977-E46A-4095-B4CF-FA4C3E0F0EE3`.

The implementation is `7af896a497af94538f6ed4a2216d48405787ae96` followed by
`9bf9e0cb043f365b22225a3a0daed449fccf3b2f`. The preliminary slice-only UIKit Debug run started
before the second commit and records the first SHA plus final changed-source
hashes in `Setup.json`; no source changed during that run. Every installed
runner records source/configuration, source hashes, compiler versions and
executable/library hashes. Evidence is under
`~/Library/Developer/Xcode/DerivedData/UndoKit/Evidence/`.

Commands:

```sh
ruby scripts/run-durable-notes-swiftui-macos.rb --check --configuration Debug
ruby scripts/run-durable-notes-swiftui-macos.rb --check --configuration Release
ruby scripts/run-durable-notes-swiftui-ios.rb --device 241ED977-E46A-4095-B4CF-FA4C3E0F0EE3 --configuration Debug
ruby scripts/run-durable-notes-swiftui-ios.rb --device 241ED977-E46A-4095-B4CF-FA4C3E0F0EE3 --configuration Release
```

Preliminary slice-only UIKit Debug and Release runs passed installed checks
and independent Note/receipt readback in
`DurableNotesSwiftUIiOS/20261016T010946Z-173414` and
`DurableNotesSwiftUIiOS/20261016T011042Z-8171de`. Debug recorded 19 observations
including injected finalization recovery; Release omits Debug-only injection.

Final installed validation uses the combined activity, presentation and position
cleanup at `9bb5acbdb6c490284c3c07c04e932773e850823c`, from the integration
checkout. This verifies the interacting backend changes with the same public
SwiftUI/native consumers.

- macOS Debug: passed 18 public host tests and installed checks;
  `DurableNotesSwiftUI/20261016T011202Z-2882fa`.
- macOS Release: passed 18 public host tests and installed checks;
  `DurableNotesSwiftUI/20261016T011225Z-d004ef`.
- iPadOS Debug: passed all 19 observations, independent receipt readback,
  recovery-owner closure and weak presentation release;
  `DurableNotesSwiftUIiOS/20261016T011251Z-e1bfee`.
- iPadOS Release: passed all 18 applicable observations, independent receipt
  readback, recovery-owner closure and weak presentation release;
  `DurableNotesSwiftUIiOS/20261016T011344Z-f3d600`.

Native input is programmatic; actual keyboard/IME interaction, floor OS, Intel,
physical-device and forced-termination qualification remain separate. The root
integration also passed the full package suites (Debug 164, Release 152, no
skips) and independent standards/spec reviews with no findings.
