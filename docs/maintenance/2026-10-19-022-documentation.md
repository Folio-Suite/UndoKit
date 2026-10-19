<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# 0.2.2 documentation hygiene — 2026-10-19

Focused documentation maintenance for the 0.2.2 beta patch preparation in
[PR #74](https://github.com/Folio-Suite/UndoKit/pull/74), starting from
`053221e9a2cf1b7b1dadefe5b4be84a162e13826`. The release identity changes from
0.2.1 build 3 to **0.2.2 build 4**. This pass prepares a reviewable source change;
it does not certify or publish a signed release candidate.

## Inventory and boundaries

The examined inventory includes the README, all ten DocC Markdown pages and the
existing ownership SVG, plus these eight current runbooks: installation,
history reconstruction, history compatibility, binary distribution, documentation
site, release preparation, release qualification and acceptance measurement plan.
Project.xcconfig, UndoKit.xcodeproj build settings, and the maintenance,
release-candidate, documentation-site and
compiled-example check entry points were also examined. The two new records are
this ledger and the 0.2.2 release notes/checklist.
Dated diagnostics, research, ADR decisions, imported design evidence and previous
maintenance reports remain historical records. A version appearing in those
records is not automatically a stale reference.

No architecture, import, dead-code, localization, dependency or runtime refactor
is included. Native Xcode build settings now inherit the central build number
instead of overriding it with 1 in both project configurations. The runtime correction's code remains at the starting revision;
version metadata, native project inheritance and documentation are the additional
release-preparation scope.

## Coverage and disposition

| Category | Disposition | Evidence and limits |
| --- | --- | --- |
| Documentation and tickets | Fixed and verified | Current entry points describe published beta history, the new per-session native-name resolver and 0.2.2 preparation. Copyable examples use the actual public API. The release checklist separates source checks from candidate qualification. #73 remains linked through PR #74; no unrelated tracker records are changed. |
| Release identity and instructions | Fixed and verified | Project.xcconfig plans 0.2.2 build 4 and native project overrides are removed; live releases/tags were checked and end at 0.2.1 build 3. Current preparation examples target 0.2.2 while dated evidence remains intact. Monotonicity must be rechecked before candidate preparation. |
| Architecture, imports, dead code | Not applicable with reason | Focused documentation pass; no Swift runtime declarations, imports, ownership boundaries or prototypes change in this additional delta. |
| Localization and resources | Not applicable with reason | Guides explain host-owned label localization. No locale catalog, runtime model, privacy manifest or other runtime resource changes. Generated documentation will be a new artifact. |
| Dependency inventory | Pass | Package manifests and resolved dependency inputs remain unchanged. |
| Diagnostics and lint | Pass | Final maintenance and DocC diagnostic results are recorded below; generated Core Data compiler warning provenance remains separate from DocC diagnostics. |
| Test health | Pass | Existing action-name and full package evidence is retained with its exact source. Changed documentation examples receive fresh compilation/execution checks; no synthetic tests of prose are added. |
| Native acceptance | Deferred with reason | The preceding implementation has passing installed AppKit and macOS consumer evidence. UIKit's later background-transition timeout and simulator-runner conflict remain explicit. New signed-artifact, OS and promotion gates are tracked in the release checklist; this audit does not waive them. |

## Validation

Xcode 27.1 (27A9275), Apple Swift 6.4, macOS 27.0.1 arm64. The additional
release-preparation delta changes documentation, Project.xcconfig and the two
project-level build-number overrides in UndoKit.xcodeproj/project.pbxproj;
framework Swift code, model/privacy resources and dependency records remain
identical to the reviewed action-name implementation at the starting revision.

| Check | Final result |
| --- | --- |
| `scripts/test-package.sh` | 167 tests, one opt-in scale skip, zero failures. |
| `scripts/test-package.sh -c release` | 155 tests, one opt-in scale skip, zero failures. |
| `ruby scripts/maintenance/check.rb` | Pass: configured lint baseline, local Markdown destinations, script syntax and preservation checks. No new lint findings. |
| `ruby scripts/release/candidate_test.rb` | 15 tests, 104 assertions, zero failures/errors/skips. Synthetic tooling tests do not establish signed-artifact qualification. |
| `ruby scripts/documentation/tests/site_test.rb` | 16 tests, 290 assertions, zero failures/errors/skips. |
| `ruby scripts/check-documentation-examples.rb --configuration Debug` and `Release` | Nine actual Swift blocks compile for Mac and iOS Simulator SDKs; persisted Mac walkthrough executes in both configurations. All five guide hashes match the final files. No simulator runtime pass is inferred. |
| Xcode `docbuild` with `OTHER_DOCC_FLAGS=--warnings-as-errors` | Pass for final catalog and symbol/article links. Full build retains twelve generated Core Data unused-public-import locations, the existing reviewed complexity-11 Debug safeguard warning and the tooling AppIntents metadata-skip diagnostic; these are not DocC failures or new documentation diagnostics. No generated-source or linter policy changes. |
| Built native framework identity | Initial Debug product exposed project-level build 1 overriding xcconfig. Removed both project overrides; final Debug Info.plist reports version 0.2.2/build 4 and Release showBuildSettings resolves the same identity. Archive production already passes explicit version/build. No signed distributable XCFramework is claimed. |
| Rendered DocC | Locally transformed landing page, ownership diagram and new resolver section inspected at normal 1280-pixel and narrow 390-pixel widths. Wrapped the new snippet to avoid unnecessary horizontal scrolling at normal width. Narrow prose and diagram remain legible; code retains standard DocC horizontal scrolling. Temporary viewport override was reset. No renderer/CSS/image change is included. |
| Standards and Spec reviews | No actionable findings in the documentation/version delta; original runtime correction reviewed separately. |

The final compiled-example evidence directories are
`20261019T230248Z-f8b879` (Debug) and `20261019T230259Z-ca715a` (Release) under
the shared DerivedData `UndoKit/Evidence/DocumentationExamples` root. Earlier
editorial runs are superseded; a checker correctly refused to certify a guide
that changed during its run. The final DocC output is a local QA preview, not
a staged or published release snapshot.

## Work ledger

| Task | Owner/model | Base and integration | State |
| --- | --- | --- | --- |
| Current onboarding/integration documentation | Bounded worker, gpt-6-luna medium | Shared checkout, disjoint Markdown ownership, base 053221e; coordinator integrated and refined localization/line wrapping | Complete |
| Release metadata, preparation records and validation | Coordinator, inherited model | Same branch/base; all Git mutations serialized here | Complete for PR preparation |
| Standards and Spec review | Separate review agents, inherited coordinator model | Additional documentation/version delta from 053221e; whole PR retains original main baseline ff37095 | No actionable findings |

See [0.2.2 preparation](../releases/0.2.2.md) for remaining artifact and runtime
qualification gates. The focused documentation audit is complete with the
explicit native-runtime deferrals above. Release readiness
and publication remain pending the candidate-specific checklist.
