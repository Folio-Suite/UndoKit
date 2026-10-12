<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Preview foundations: issues 13–15

This bounded batch implements the source/project consumers, safe opening and
persistence-failure evidence from issues [13](https://github.com/Folio-Suite/UndoKit/issues/13),
[14](https://github.com/Folio-Suite/UndoKit/issues/14) and
[15](https://github.com/Folio-Suite/UndoKit/issues/15). The implementation base is
`6c8eb91c5d3fdf7d89473a6ce0bf769bbee1f295`. The source diff and commit history
identify the resulting implementation; this report is not a release seal.

## Setup and preservation

Local producer: Xcode 27.0 (27A266a), Apple Swift 6.4, Swift 6 language mode,
macOS 27.0.1, arm64. `ruby scripts/check-toolchain.rb` verifies the producer
pin. Build output and retained local evidence use ignored `DerivedData/`.

Safe-opening tests first reproduced a rejected working-identity open changing
SQLite shared-memory bytes. Validation now happens on an isolated snapshot,
and read-only inspection uses that snapshot throughout its lifetime. Nine
focused cases pass, including missing, corrupt, incompatible/newer, unregistered
and incorrectly bound stores, WAL-backed inspection, and a paired baseline.
The tests compare the original database and sidecar bytes before and after
refusal or inspection.

The concrete unsealed development baseline and checksums were retained locally
under `DerivedData/PreviewEvidence/`. The committed recipe, generator, paired
host-state requirements and future sealing procedure are documented in
[history compatibility](../history-compatibility.md). The unchanged model source
hash is `fb9cfc0dc5af28bb95cd26283abe4f214009cb28f438b2507fb9784bc6331532`.

## Package and failure-boundary validation

The integrated production changes passed both full package suites:

| Command | Result |
| --- | --- |
| `swift test --scratch-path DerivedData/PackageDebug` | 96 passed, 1 skipped, 0 failures |
| `swift test -c release --scratch-path DerivedData/PackageRelease` | 88 passed, 1 skipped, 0 failures |

Eight Debug-only injection cases are absent from Release. The opt-in scale
case is skipped in both configurations. The detailed
[persistence-failure evidence](../persistence-failure-evidence.md) maps public
behavior to production save/copy boundaries, durable host receipts and retained
resources. It includes the corrected pre-delivery failure classification and
copy refusal when destination sidecars already exist. Local full-suite logs are
`DerivedData/PreviewEvidence/package-debug.log` and `package-release.log`.

## Qualification boundary

These checks do not qualify a published release, XCFramework, Intel execution,
deployment-floor OS, physical iPhone/iPad, signing or installation outside the
consumer harness. Failure injection and graceful close/reopen do not simulate
an exhausted disk or abrupt process termination. Final candidate fixture sealing
and the remaining preview gates stay in the release plan.
