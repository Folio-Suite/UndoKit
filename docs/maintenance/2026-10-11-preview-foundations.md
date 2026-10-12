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
That initial SwiftLint run completed with zero errors and 42 warnings, including
existing warnings and new long preservation-test bodies/files. The follow-up
cleanup below supersedes that lint baseline.

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
remain in place; the follow-up cleanup now shares their nonmutating validation.
Spec: zero actionable
findings against issues 13–15 and accepted decisions 5–8. The subsequent
same-file test extension split changes layout only and has focused Debug/Release
validation above.

## Qualification boundary

These checks do not qualify a published release, XCFramework, Intel execution,
deployment-floor OS, physical iPhone/iPad, signing or installation outside the
consumer harness. Failure injection and graceful close/reopen do not simulate
an exhausted disk or abrupt process termination. Final candidate fixture sealing
and the remaining preview gates stay in the release plan.

## Analyze follow-up (2026-10-12)

The native Analyze log invoked the build plugin's `swiftlint lint`, not
`swiftlint analyze`. It reported 20 framework lint warnings; a repository-wide
lint run also found 22 test warnings. The follow-up separates payload storage,
store registration, delivery recovery, accepted-outcome finalization and
retention selection into cohesive helpers, preserving durable save order and
public behavior. Opening preflight and live independent-copy registration share
one nonmutating binding check. Test scenarios retain their assertion coverage
while fixture construction and related scenarios have focused helpers/files.

The public recording case `.on` retains its domain name with a single
`identifier_name` exception at that declaration. No thresholds or repository-wide
rules were relaxed. Repository-wide SwiftLint now reports zero warnings and zero
errors. Generated Core Data public-import diagnostics remain tracked separately
in [#31](https://github.com/Folio-Suite/UndoKit/issues/31); generated sources were
not edited. The user's local project DerivedData setting was preserved.

Fresh verification after cleanup:

- Focused opening, persistence, retention, lifecycle and recording: 48 passed.
- Full Debug: 96 passed, one opt-in scale test skipped, zero failures.
- Full Release: 88 passed, one opt-in scale test skipped, zero failures.
- Separate 200-group scale run: passed; 199 far-back reconstruction steps,
  101 divergent steps, three groups consolidated in one pass.
- Native Xcode build: passed using project-local `DerivedData/UndoKit`.

Logs are retained under `DerivedData/PreviewEvidence/cleanup-*.log`, with
`swiftlint-cleanup.log` empty because the quiet lint run emitted no diagnostics.

Separate incremental reviews of `c197fcc...63dda2a` returned zero standards
violations or actionable smells, and zero spec findings. Review checked the
save fences, rollback paths, lock lifetime, copy validation, retention protection
and preserved test assertions.

The prior pushed CI run passed package tests and the package simulator route,
then failed at the native framework build. Its diagnostic filter omitted the
underlying error. The consumer runner now emits the complete output of a failed
command so fresh CI retains the actual cause; no speculative build-setting or
plugin-trust change is included.

Fresh consumer runs also passed all eight route/platform/configuration cases
after cleanup, with `alpha-beta`, three receipts and six member applications in
every report. Retained local evidence:

- Debug: `DerivedData/Consumers/kept-20261012T052158Z-22ff70/ConsumerEvidence.json`
- Release: `DerivedData/Consumers/kept-20261012T052409Z-0a4143/ConsumerEvidence.json`

These runs cover the reviewed Swift cleanup; the subsequent runner change only
expands output on failure. Separate follow-up standards/spec reviews of that
runner diagnostic change and this evidence record found no actionable issues.

## CI plugin approval follow-up

All four checks for `c5d51bd` (Debug/Release on push and pull-request events)
failed Xcode's `Validate plug-in SwiftLintBuildToolPlugin` step before native
compilation. The complete failed-command logs exposed the shared failure.
Following KitchenMemory's CI pattern, hosted native builds now use
`-skipPackagePluginValidation` after the workflow validates the exact reviewed
SwiftLint package revision and repository URL. Native builds also require
`Package.resolved`. Local builds retain interactive Xcode approval behavior.
A changed dependency pin is refused until the reviewed revision is updated.
The initial manual trust-file approach was superseded by this CLI pattern.

Ruby syntax, exact-pin acceptance, changed-pin refusal, and CI-only flag
selection passed. The pinned native universal macOS build passed locally;
the fresh hosted run remains the authoritative test of the CI approval gate.
