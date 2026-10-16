<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Architecture cleanup integration — 2026-10-15

This report covers issues #59 (activity ownership), #60 (SwiftUI presentation
ownership) and #61 (Undo/Redo Position policy). The starting source was
`574d923952becf28d4866e018bd65c22600e529a`. The final combined implementation was
validated at integration commit `9bb5acbdb6c490284c3c07c04e932773e850823c`:

- Activity source: `1c840c55f759850616228e49382c052a1656bc72`.
- Presentation source: `9bf9e0cb043f365b22225a3a0daed449fccf3b2f`.
- Position source: `67c097a`, stacked on activity as `d60b0a4` with the same
  coordinator-property resolution used by the integration checkout.

Subsequent documentation commits record evidence without changing executable
source. The activity and presentation PRs are independent; the Position PR depends
on activity. The maintainer owns CI and merging.

## Environment and package checks

Xcode 27.0 (27A266a), Apple Swift 6.4, macOS 27.0.1 (26A434), arm64. All runners
used the shared default DerivedData location; native producers ran serially.

```sh
ruby scripts/check-toolchain.rb
UNDOKIT_SCALE_SMOKE=1 scripts/test-package.sh
UNDOKIT_SCALE_SMOKE=1 scripts/test-package.sh -c release
ruby scripts/maintenance/check.rb
ruby scripts/maintenance/check-fixtures.rb
ruby scripts/documentation/tests/site_test.rb
```

Toolchain and maintenance passed. The complete package suites passed 164 Debug
and 152 Release tests with zero failures and zero skips, including bounded scale
smoke, persistence failures, authoritative recovery, recording switches,
invalidation, cancellation, generation retirement and late native rejection.
Maintenance fixtures passed seven success/failure cases. Documentation tests
passed 16 tests and 280 assertions. Existing generated Core Data unused-import
warnings and the existing captured-mutation warning remain visible.

Independent Standards and Spec reviewers examined the immutable integrated
base/head above. Each reported zero actionable findings. Neither claimed to have
independently run the runtime matrix.

## Installed SwiftUI consumers

```sh
ruby scripts/run-durable-notes-swiftui-macos.rb --check --configuration Debug
ruby scripts/run-durable-notes-swiftui-macos.rb --check --configuration Release
ruby scripts/run-durable-notes-swiftui-ios.rb --device 241ED977-E46A-4095-B4CF-FA4C3E0F0EE3 --configuration Debug
ruby scripts/run-durable-notes-swiftui-ios.rb --device 241ED977-E46A-4095-B4CF-FA4C3E0F0EE3 --configuration Release
```

All four integrated runs passed. macOS Debug/Release each passed the 18 public
hosted-editor tests plus installed native checks. The iPad iOS 26.5 simulator
Debug run passed 19 runtime observations; Release passed 18. Both passed
independent persisted Note/receipt readback. Ownership release, recovery-owner
closure and presentation release were verified. The runner shut down the supplied simulator after booting it.

Evidence directories beneath `~/Library/Developer/Xcode/DerivedData/UndoKit/Evidence`:

| Configuration | Relative evidence directory |
| --- | --- |
| macOS Debug | `DurableNotesSwiftUI/20261016T011202Z-2882fa` |
| macOS Release | `DurableNotesSwiftUI/20261016T011225Z-d004ef` |
| iOS Debug | `DurableNotesSwiftUIiOS/20261016T011251Z-e1bfee` |
| iOS Release | `DurableNotesSwiftUIiOS/20261016T011344Z-f3d600` |

The new AppKit fixture explicitly disables release-on-close for Swift-owned test
windows. The UIKit overlap probe disposes controlled UIHostingController roots:
hiding a SwiftUI Form row does not promise representable dismantling. These
fixture corrections preserve production visibility behavior.

## Independent package and framework consumers

```sh
scripts/check-consumer.sh --route both --platform both --configuration Debug --device 241ED977-E46A-4095-B4CF-FA4C3E0F0EE3
scripts/check-consumer.sh --route both --platform both --configuration Release --device 241ED977-E46A-4095-B4CF-FA4C3E0F0EE3
```

Both configurations passed all five reports: the package command-line consumer,
package macOS/iOS apps and native-framework macOS/iOS apps. Every report verified
`alpha-beta`, three receipts, six applied members, and reopened Undo availability
without Redo availability. Installed apps proved one shared UndoKit runtime
identity, bundled model/privacy resources and expected deployment/load commands.
Native macOS products contained arm64 and x86_64; runtime execution was arm64.
The simulator executed iOS 26.5 (23F77).

Debug recorded source `9bb5acbdb6c490284c3c07c04e932773e850823c`. Release recorded
`11231ee722660b088f509da54a8a1b03b9492993`, which adds only the final SwiftUI
evidence document; executable source was verified identical. Temporary generated
stores/projects were removed by the runner; shared build caches remain.
Configuration logs and extracted `ConsumerEvidence.json` summaries were retained
under `/private/tmp/undokit-cleanup-consumers-{debug,release}*`. The summaries
include source, runtime and model/privacy artifact hashes.

## Preserved boundaries

SHA-256 verification confirmed `Package.swift`, the navigator project file, the
Core Data model/version selector and privacy manifest match the starting source.
Public declarations and host responsibilities remain unchanged. Durable and
transient representations remain distinct. No release candidate, tag or binary
release was modified.

This matrix ran on the current local macOS and iOS simulator environments. It
does not add floor-OS execution, physical-device execution, Intel runtime evidence,
or manual keyboard/IME qualification. It does not replace the separately tracked
OS qualification work.
