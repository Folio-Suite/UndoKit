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

After a lint-only split of the persistence test class into same-file extensions,
focused rediscovery passed all nine Debug and two Release persistence tests.
SwiftLint completed with zero errors and 42 warnings, including existing
warnings and new long preservation-test bodies/files. No lint rules were disabled.

## Independent consumer results

The source-package and native-project routes both completed the grouped
Command → Undo → Redo → close/reopen workload on macOS 27.0.1 arm64 and
iOS 27.0 (24A434) arm64 Simulator in Debug and Release. Each fresh host loaded
three durable receipts and six member applications, ending at `alpha-beta`
with Undo available and Redo unavailable. Native macOS and simulator framework
products contain arm64 and x86_64; runtime evidence here covers arm64.

Checks locate compiled `HistoryV1.mom` and the privacy manifest in the package
resource bundle or embedded native framework, compare privacy declarations to
source, and record SHA-256 artifact identities. Generated apps are checked for
an embedded runtime, the correct loader search path, Mach-O platform and exact
deployment floor before launch. The retained JSON summaries include producer,
source revision/dirty paths, runtime setup and results. Reproduce with:

```sh
scripts/check-consumer.sh --route both --platform both --configuration Debug --keep
scripts/check-consumer.sh --route both --platform both --configuration Release --keep
```

The complete Release result is retained locally at
`DerivedData/Consumers/kept-20261012T050326Z-052464/ConsumerEvidence.json`.
Current-source Debug evidence is retained under the same parent in
`kept-20261012T050630Z-02731f` (native macOS and simulator),
`kept-20261012T050650Z-0eb915` (package macOS), and
`kept-20261012T050428Z-0c1e1d` (package simulator), each with its own
`ConsumerEvidence.json`. Earlier Debug attempts are superseded by these runs.
Those development artifacts identify the source snapshot and are not a
clean-tree release seal. The initial Release package simulator attempt failed
at dynamic loading: the generated project lacked a runtime search path and
its package embed reference was incorrect. Correcting the generator and adding
prelaunch checks produced the successful runtime result; an earlier build-only
success was not counted as a runtime pass.

## Review

Separate standards and spec reviews compared
`6c8eb91c5d3fdf7d89473a6ce0bf769bbee1f295` with
`1fee2c3fb8af9a8f6dbe3f134e1d431042f8f481`.
Standards: zero hard violations, one optional duplication refactor around
independent-copy binding validation. Both preflight and live-context checks
remain in place; sharing their predicate is deferred. Spec: zero actionable
findings against issues 13–15 and accepted decisions 5–8. The subsequent
same-file test extension split changes layout only and has focused Debug/Release
validation above.

## Qualification boundary

These checks do not qualify a published release, XCFramework, Intel execution,
deployment-floor OS, physical iPhone/iPad, signing or installation outside the
consumer harness. Failure injection and graceful close/reopen do not simulate
an exhausted disk or abrupt process termination. Final candidate fixture sealing
and the remaining preview gates stay in the release plan.
