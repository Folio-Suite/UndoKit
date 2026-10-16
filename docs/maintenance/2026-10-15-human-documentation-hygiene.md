<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Whole-repository hygiene and human documentation — 2026-10-15

Periodic maintenance, starting at `aa891195486aa7891cb3d0f9c5f4a0d8d1f6bd24` on
`codex/human-first-documentation-hygiene`. This is an editorial/mechanical pass,
not release qualification. No tracker mutation, publication, merge, release tag,
immutable candidate edit or toolchain-template edit is part of it.

## Coverage and disposition

The final inventory comprises 318 project files: 164 Swift sources/manifests,
28 Ruby scripts, two shell runners, 89 Markdown documents and 35 other project,
resource, fixture and configuration files. All source import declarations were
inventoried, including standalone tools, examples and retained prototypes.
Generated build output is excluded from project-source counts and examined
separately below. This inventory is not a claim of semantic unreachability proof
for every private declaration or manual testing on every OS.

| Category | Disposition | Evidence and result |
| --- | --- | --- |
| Architecture | Pass | Inspected the shared-session interface and recent activity/presentation/Position owners against CONTEXT and accepted ADRs. The coordinator owns the sole Command FIFO; store/scope activity own exclusion, native presentation owns weak arbitration, and Position policy retains distinct durable/transient representations. No new abstraction or architecture reversal. |
| Localization | Deferred with reason | Framework fallback diagnostics/accessibility strings and example UI remain English. There is no declared additional locale inventory. No plurals/format placeholders or translator resources were introduced; adding language support needs an explicit locale scope. |
| Resources | Fixed and verified | Runtime model, version selector, privacy manifest and target membership remain byte-identical. Eleven existing XML/plist inputs parse. The new authored SVG has license, title/description and a DocC alt description; its rendered size was adjusted for narrow readers. Installed resource evidence from the preceding unchanged-runtime matrix remains applicable. |
| Imports and dependency direction | Pass | All 164 Swift files accounted for in the appendix; no duplicate import directives. No platform framework import enters Storage, Transactions, HostAdaptation or RetainedHistory. Conditional native files, direct annotations, Objective-C selectors and Core Data key paths were retained. No speculative unused-import deletion. |
| Dead code and prototypes | Pass | Recent superseded state owners remain removed; no competing legacy session integration was added. Prototype packages remain deliberately retained reference fixtures under the handoff/UPSTREAM policy; preservation checks pass. Native selectors, generated model symbols and programmatic-only initializer traps are intentional. No unproved deletion. |
| Diagnostics and lint | Fixed and verified | SwiftLint 0.65.1: nine findings before, one afterward. Eight mechanical findings/exemptions removed without changing rules/thresholds. The remaining complexity-11 Debug save-injection switch is one cohesive stage-addressed safeguard; its reviewed baseline remains. The captured-mutation warning is removed by observing the existing MainActor host gate instead of a captured mutable flag. Twelve generated Core Data unused-public-import warning locations remain per package configuration. |
| Test health | Fixed and verified | Full Debug 164 and Release 152 tests passed, zero failures/skips, with scale smoke enabled. Failure-guard early returns and fixture UTF-8 decoding are explicit; malformed UTF-8 is rejected by the bounded text fixture. Persistence, recovery, cancellation and original-data assertions remain intact. The new documentation checker exercises the actual extracted examples and independently reads the persisted host state/receipts after reopen. |
| Dependency inventory | Pass | Package.swift is unchanged, with one dynamic UndoKit library and the existing scale tools. No runtime third-party package added. Xcode's only resolved package is the build-time SwiftLint plugin 0.65.1 at `ef7d692fc6706e8f5628e26bcafaefa445c58a97`; existing pin/config checks pass. MIT/imported notices and privacy declarations remain. Every Swift/Ruby/shell/SVG source and changed/new Markdown carries its required SPDX notice. |
| Documentation and tickets | Fixed and verified | README and DocC now start from a runnable note and lead through typed edits, AppKit/UIKit/SwiftUI wiring, host atomicity and recovery. Four integration articles live under Integration/. Added API member documentation and MARK navigation. Corrected the duplicate ADR number: OS qualification is ADR 0008; shared sessions remain ADR 0007. Seven live open issues still describe qualification/site/release work; only 0.1.0 is published. Tracker unchanged. |
| Native acceptance | Deferred with reason | Runtime implementation and public declarations are unchanged; prior integrated installed AppKit/UIKit/SwiftUI evidence is reused. Fresh guide snippets compile for both SDK branches and configurations; their Mac durable flow executes. No new simulator app, real typing/IME, physical-device or floor-OS run is claimed. Those behavioral/release gates remain under #23/#26/#27 and the qualification policy. |

## Human integration path

- README: run Durable Notes, pick AppKit/UIKit/SwiftUI, then adapt the host model.
- DocC landing page: short ownership explanation and an accessible vector diagram,
  followed by guided integration and curated ordinary symbols.
- First Undo Group: complete shared `NoteDocument` wrapper and typed rename;
  `DurableNotesCore` types are explicitly distinguished from UndoKit API.
- Platform guides: actual attachment/editor/UndoManager wiring, retained owners,
  SwiftUI observation, lifecycle and draft/recovery responsibilities.
- Host guide: operation registration, stable intent, complete-group atomicity,
  durable token receipts and authoritative outcome lookup. No in-memory pretend
  host is presented as durable integration.

The new `scripts/check-documentation-examples.rb` extracts eight Swift blocks
from five guides. It builds them against the actual UndoKit/DurableNotesCore
products. Mac execution verifies rename, Undo to the empty title, Redo, closure,
reopen, three host receipts/applications, and correct reopened availability.
iOS is a Simulator-SDK compile check only. It has a shared cache lock and records
guide hashes, source/diff identity, configuration, toolchain and actual checks.
No generated consumer becomes a distributed product or runtime dependency.

## Validation

Xcode 27.0 (27A266a), Swift 6.4, macOS 27.0.1 (26A434), arm64. iOS snippets compile
against the iOS 27.0 Simulator SDK with a declared iOS 17 floor; this is not an
iOS 27 runtime pass. Shared DerivedData is used throughout.

```sh
UNDOKIT_SCALE_SMOKE=1 scripts/test-package.sh
UNDOKIT_SCALE_SMOKE=1 scripts/test-package.sh -c release
ruby scripts/check-documentation-examples.rb --configuration Debug
ruby scripts/check-documentation-examples.rb --configuration Release
ruby scripts/maintenance/check.rb
ruby scripts/maintenance/check-fixtures.rb
ruby scripts/documentation/tests/site_test.rb
```

Results: package Debug 164 / Release 152 passed; documentation checker eight
blocks, both SDKs/configurations passed; seven maintenance success/failure
fixtures passed; documentation tooling 16 tests / 280 assertions passed.
The strict DocC builds use `xcodebuild -project UndoKit.xcodeproj -scheme UndoKit
-destination 'generic/platform=macOS'` and `'generic/platform=iOS Simulator'`,
`docbuild` and `OTHER_DOCC_FLAGS="--warnings-as-errors --diagnostics-file …"`.
Both report zero DocC diagnostics. The public API comments resolve successfully.
Runtime model/resources, Package.swift, Package.resolved and the navigator
project match the base bytes. Local Markdown destinations, runner syntax,
original imported-artifact checksums and `git diff --check` pass.

Documentation example evidence beneath the shared DerivedData `Evidence` root:

- Debug: `DocumentationExamples/20261016T015016Z-ebbb06`.
- Release: `DocumentationExamples/20261016T015147Z-3bace3`.

Package/check logs are retained as `/private/tmp/undokit-hygiene-*`. Source was
an explicitly dirty development checkout during the checks; guide hashes and
source diff identity are retained. No release artifact is implied.

The maintained documentation producer and development staging commands passed
against clean implementation commit `8051c3e8b75495deea0118d81a332c2f48e67469`.
The local artifact is `/private/tmp/undokit-hygiene-docs-20261015`:

- Archive SHA-256: `e6a54a63c36ecdfca66c291b3d03aac96a02195baf38708705a996b78de7fc6d`.
- Site SHA-256: `c245918b06ea069d98b573cd5ce1eaeaa476994f3ce12259c4ada38fae8c3d7a`.

Staging validated deep refresh, search, assets and link integrity. Browser
inspection of the staged landing page and first-group guide confirmed readable
diagram labels, navigation, prose and syntax-highlighted code. Both SDK archives
contain the current SVG bytes. This is local development staging, with no public
deployment or candidate promotion. The separate report-only commit does not
change the implementation artifact above.

## Generated-code finding

Visual inspection found `History…CoreDataPropertiesSet` and framework typealiases
in the generated symbol reference. An initial stale-cache hypothesis was ruled
out: a clean docbuild and direct `momc --action generate` in a fresh temporary
directory reproduce them. The installed Xcode templates under
`IDEModelFoundation.framework/.../NSManagedObject subclass.xctemplate` contain
those public aliases. They are not declarations added by this repository pass.
No claim that the installed templates are modified or corrupted is made.

The compiler's generated Core Data import warning remains visible. We did not
edit generated files, add source aliases or weaken visibility just to satisfy it.
The onboarding story uses the supported session/host interface; generated support
symbols are not an integration recipe. Revisiting toolchain-generated reference
noise is a separate toolchain/documentation-policy decision.

## Limits and follow-through

This audit is complete when the final inventory and checks above are accounted
for; it does not qualify a new release candidate. Localization expansion,
floor/current OS execution, full production scale and targeted physical behavior
remain explicit separate work. Existing immutable candidate bytes are untouched.
Public DocC deployment/version promotion is still separate from local generation.

## Independent review

### Standards

Pass, with no actionable findings, reviewing implementation commit `8051c3e`
against base `aa89119`. The independent reviewer checked repository guidance,
licensing, dependency direction, public declarations, maintenance conventions
and the verification helper's scope.

### Spec

Pass, with no actionable findings at the same commit pair. The independent
reviewer checked the human integration path for all three UI frameworks,
app-owned sample types, host atomicity and receipts, shared ownership, SwiftUI
observation, blocked closure and accurate compile/runtime acceptance limits.
These were independent source reviews; their conclusions do not claim additional
hardware runs. The parent audit supplies the execution and visual evidence above.

## Source/import appendix

Every Swift source/manifest below was included in the import inventory. Empty
imports mean standard-library-only code. Platform conditions were recorded rather
than removed. Production imports were checked for direction; tools,
package manifests, prototypes and Objective-C/native paths retain their own
requirements. This is an inventory/reference audit, not an unused-import
compiler guarantee for inactive branches.

| Source | Imports in source order | Conditional compilation |
| --- | --- | --- |
| `Examples/DurableNotes/Package.swift` | `PackageDescription` | No |
| `Examples/DurableNotes/Sources/DurableNotesApp/NativeChecks.swift` | `AppKit`, `Darwin`, `DurableNotesCore`, `UndoKit` | Yes |
| `Examples/DurableNotes/Sources/DurableNotesApp/NotesWindowController.swift` | `AppKit`, `DurableNotesCore`, `UndoKit` | Yes |
| `Examples/DurableNotes/Sources/DurableNotesApp/main.swift` | `AppKit`, `DurableNotesCore` | No |
| `Examples/DurableNotes/Sources/DurableNotesCore/DurableNotesHost.swift` | `Foundation`, `UndoKit` | Yes |
| `Examples/DurableNotes/Sources/DurableNotesCore/Note.swift` | `Foundation`, `UndoKit` | No |
| `Examples/DurableNotes/Sources/DurableNotesCore/NotesDocumentLease.swift` | `Foundation`, `UndoKit` | Yes |
| `Examples/DurableNotes/Sources/DurableNotesCore/NotesDocumentRegistry.swift` | `Foundation`, `UndoKit` | No |
| `Examples/DurableNotes/Sources/DurableNotesCore/NotesSession.swift` | `Foundation`, `UndoKit` | Yes |
| `Examples/DurableNotes/SwiftUI/Sources/DurableNotesSwiftUIApp.swift` | `SwiftUI` | No |
| `Examples/DurableNotes/SwiftUI/Sources/SwiftUIChecks.swift` | `Darwin`, `SwiftUI`, `UIKit`, `DurableNotesCore`, `UndoKit` | Yes |
| `Examples/DurableNotes/SwiftUI/Sources/SwiftUINotesScene.swift` | `SwiftUI`, `UIKit`, `DurableNotesCore`, `UndoKit` | No |
| `Examples/DurableNotes/SwiftUIApp/Sources/NativeChecks.swift` | `AppKit`, `Darwin`, `DurableNotesCore`, `UndoKit` | Yes |
| `Examples/DurableNotes/SwiftUIApp/Sources/main.swift` | `AppKit`, `Combine`, `DurableNotesCore`, `SwiftUI`, `UndoKit` | Yes |
| `Examples/DurableNotes/Tests/DurableNotesCoreTests/NotesAppKitBindingTests.swift` | `AppKit`, `DurableNotesCore`, `UndoKit`, `XCTest` | No |
| `Examples/DurableNotes/Tests/DurableNotesCoreTests/NotesNativeSessionTests.swift` | `DurableNotesCore`, `Foundation`, `UndoKit`, `XCTest` | No |
| `Examples/DurableNotes/Tests/DurableNotesCoreTests/NotesSessionTests.swift` | `DurableNotesCore`, `Foundation`, `XCTest` | Yes |
| `Examples/DurableNotes/Tests/DurableNotesCoreTests/NotesSwiftUIAppKitTests.swift` | `AppKit`, `DurableNotesCore`, `SwiftUI`, `UndoKit`, `XCTest` | No |
| `Examples/DurableNotes/UIKit/Sources/AppDelegate.swift` | `UIKit`, `DurableNotesCore`, `UndoKit` | No |
| `Examples/DurableNotes/UIKit/Sources/NotesSceneOwner.swift` | `UIKit`, `DurableNotesCore`, `UndoKit` | No |
| `Examples/DurableNotes/UIKit/Sources/NotesUIKitController.swift` | `UIKit`, `DurableNotesCore`, `UndoKit` | Yes |
| `Examples/DurableNotes/UIKit/Sources/UIKitChecks.swift` | `UIKit`, `DurableNotesCore`, `UndoKit`, `Darwin`, `MachO` | Yes |
| `Package.swift` | `PackageDescription` | No |
| `UndoKit/Interface/Advanced/HistoryLocalCommands.swift` | `Foundation` | No |
| `UndoKit/Interface/Advanced/HistorySessionAdvanced.swift` | `Foundation` | No |
| `UndoKit/Interface/Advanced/RetainedHistory/HistoryReading.swift` | `Foundation` | No |
| `UndoKit/Interface/Advanced/RetainedHistory/HistoryReconstruction.swift` | `Foundation` | No |
| `UndoKit/Interface/Advanced/RetainedHistory/HistoryRetentionManaging.swift` | `Foundation` | No |
| `UndoKit/Interface/Advanced/RetainedHistory/HistoryRetentionResources.swift` | `Foundation` | No |
| `UndoKit/Interface/Advanced/Storage/HistoryStore.swift` | `CoreData`, `Darwin`, `Foundation` | Yes |
| `UndoKit/Interface/Advanced/Transactions/HistoryDebugFailureInjection.swift` | `Foundation` | Yes |
| `UndoKit/Interface/Advanced/Transactions/HistoryEngine.swift` | `Foundation` | No |
| `UndoKit/Interface/Advanced/Transactions/HistoryGeneration.swift` | `Foundation` | No |
| `UndoKit/Interface/Advanced/Transactions/HistoryRecording.swift` | `Foundation` | No |
| `UndoKit/Interface/Advanced/Transactions/HistorySessionLifecycle.swift` | `Foundation` | No |
| `UndoKit/Interface/Advanced/Transactions/HistoryTransactions.swift` | `Foundation` | No |
| `UndoKit/Interface/Application/AppKit/NativeHistoryAppKit.swift` | `AppKit` | Yes |
| `UndoKit/Interface/Application/HistoryAttachment.swift` | `Foundation` | No |
| `UndoKit/Interface/Application/HistoryCommands.swift` | `Foundation` | Yes |
| `UndoKit/Interface/Application/HistoryField.swift` | `Foundation` | No |
| `UndoKit/Interface/Application/HistorySession.swift` | `Foundation` | Yes |
| `UndoKit/Interface/Application/HistorySessionTypes.swift` | `Foundation` | No |
| `UndoKit/Interface/Application/HistorySessions.swift` | `Foundation` | No |
| `UndoKit/Interface/Application/SwiftUI/NativeHistorySwiftUI.swift` | `SwiftUI`, `UIKit` | Yes |
| `UndoKit/Interface/Application/SwiftUI/NativeHistorySwiftUIAppKit.swift` | `AppKit`, `SwiftUI` | Yes |
| `UndoKit/Interface/Application/UIKit/NativeHistoryUIKit.swift` | `UIKit` | Yes |
| `UndoKit/Interface/HistoryFailure.swift` | `Foundation` | No |
| `UndoKit/Interface/HistoryRetention.swift` | `Foundation` | No |
| `UndoKit/Interface/HistoryTypes.swift` | `Foundation` | No |
| `UndoKit/Interface/Hosting/HistoryCodecs.swift` | `Foundation` | No |
| `UndoKit/Interface/Hosting/HistoryHostRegistry.swift` | `Foundation` | No |
| `UndoKit/Interface/Hosting/HistoryOperation.swift` | `Foundation` | No |
| `UndoKit/Interface/Hosting/HistoryTypedHosting.swift` | `Foundation` | No |
| `UndoKit/Modules/HostAdaptation/HistoryCodecEnvelope.swift` | `Foundation` | No |
| `UndoKit/Modules/HostAdaptation/HistoryFamilyRouter.swift` | `Foundation` | No |
| `UndoKit/Modules/HostAdaptation/HistoryFoundationCodecs.swift` | `Foundation` | No |
| `UndoKit/Modules/HostAdaptation/HistoryRegistrationValidation.swift` | `Foundation` | No |
| `UndoKit/Modules/HostAdaptation/HistorySessionOperation.swift` | `Foundation` | No |
| `UndoKit/Modules/NativeEditing/AppKitHistoryBinding.swift` | `AppKit` | Yes |
| `UndoKit/Modules/NativeEditing/AppKitHistoryObservation.swift` | `Foundation`, `AppKit` | Yes |
| `UndoKit/Modules/NativeEditing/HistoryFieldJournal.swift` | `Foundation` | Yes |
| `UndoKit/Modules/NativeEditing/HistoryNativeCoordinator.swift` | `Foundation` | No |
| `UndoKit/Modules/NativeEditing/HistoryNativeRecovery.swift` | `Foundation` | No |
| `UndoKit/Modules/NativeEditing/HistoryNativeSettlement.swift` | `Foundation` | No |
| `UndoKit/Modules/NativeEditing/HistoryPreparedEvidence.swift` | `Foundation` | No |
| `UndoKit/Modules/NativeEditing/NativeHistoryPresentationOwnership.swift` | None | No |
| `UndoKit/Modules/NativeEditing/UIKitHistoryBinding.swift` | `UIKit` | Yes |
| `UndoKit/Modules/NativeEditing/UIKitHistoryRouting.swift` | `UIKit` | Yes |
| `UndoKit/Modules/RetainedHistory/HistoryConsolidation.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/RetainedHistory/HistoryConsolidationStorage.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/RetainedHistory/HistoryPresentation.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/RetainedHistory/HistoryQueries.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/RetainedHistory/HistoryRecoveryIntegrity.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/RetainedHistory/HistoryRecoveryPlanning.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/RetainedHistory/HistoryRetentionHolds.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/RetainedHistory/RetainedHistory.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/Sessions/HistorySessionOwnership.swift` | `Foundation` | No |
| `UndoKit/Modules/Sessions/HistorySessionPresentation.swift` | `Foundation` | No |
| `UndoKit/Modules/Sessions/HistorySessionStoreOwner.swift` | `Foundation` | No |
| `UndoKit/Modules/Storage/HistoryEngineStorage.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/Storage/HistoryManagedRecords.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/Storage/HistoryPayloadStorage.swift` | `CoreData`, `CryptoKit`, `Foundation` | No |
| `UndoKit/Modules/Storage/HistoryResourceMaintenance.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/Storage/HistoryResourceStorage.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/Storage/HistoryScopeActivity.swift` | `Foundation` | No |
| `UndoKit/Modules/Storage/HistoryScopeStorage.swift` | `CoreData`, `Foundation` | Yes |
| `UndoKit/Modules/Storage/HistoryStoreActivity.swift` | `Foundation` | No |
| `UndoKit/Modules/Storage/HistoryStoreRegistration.swift` | `CoreData`, `Foundation` | Yes |
| `UndoKit/Modules/Storage/HistoryStoreStorage.swift` | `CoreData`, `Darwin`, `Foundation` | Yes |
| `UndoKit/Modules/Transactions/HistoryAdmittedExecution.swift` | `Foundation` | Yes |
| `UndoKit/Modules/Transactions/HistoryAvailability.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/Transactions/HistoryDelivery.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/Transactions/HistoryFinalization.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/Transactions/HistoryGenerationChanges.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/Transactions/HistoryPositionPolicy.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/Transactions/HistoryReconciliation.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/Transactions/HistoryRecordingChanges.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/Transactions/HistoryTransactionAdmission.swift` | `CoreData`, `Foundation` | No |
| `UndoKit/Modules/Transactions/HistoryTransactionCoordinator.swift` | `CoreData`, `Foundation` | Yes |
| `UndoKitTests/HistoryActivityAdmissionTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryApplicationSessionFixture.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryApplicationSessionLifetimeTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryApplicationSessionQueueTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryApplicationSessionTests.swift` | `Foundation`, `XCTest`, `UndoKit` | Yes |
| `UndoKitTests/HistoryCodecTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryDebugFailureInjectionTests.swift` | `Foundation`, `UndoKit`, `XCTest` | Yes |
| `UndoKitTests/HistoryFailureTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryInverseInvalidationTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryNativeCoordinatorTests.swift` | `Foundation`, `XCTest`, `UndoKit` | No |
| `UndoKitTests/HistoryNativeDetachedRecoveryTests.swift` | `Foundation`, `XCTest`, `UndoKit` | No |
| `UndoKitTests/HistoryNativeDiscardTests.swift` | `Foundation`, `XCTest`, `UndoKit` | No |
| `UndoKitTests/HistoryNativeLifetimeTests.swift` | `Foundation`, `XCTest`, `UndoKit`, `AppKit` | Yes |
| `UndoKitTests/HistoryNativeRecoveryTests.swift` | `Foundation`, `XCTest`, `UndoKit` | Yes |
| `UndoKitTests/HistoryNativeRestoredDecisionTests.swift` | `Foundation`, `XCTest`, `UndoKit` | No |
| `UndoKitTests/HistoryNativeTestFixture.swift` | `Foundation`, `XCTest`, `UndoKit` | No |
| `UndoKitTests/HistoryOpeningActivityTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryOpeningCompatibilityTests.swift` | `CoreData`, `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryPersistenceFailureFixture.swift` | `Foundation`, `UndoKit`, `XCTest` | Yes |
| `UndoKitTests/HistoryPersistenceFailureTests.swift` | `Foundation`, `UndoKit`, `XCTest` | Yes |
| `UndoKitTests/HistoryPositionPolicyTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryPrerequisiteCancellationTests.swift` | `Foundation`, `XCTest`, `UndoKit` | No |
| `UndoKitTests/HistoryPreviewBaselineTests.swift` | `Foundation`, `UndoKit`, `XCTest` | Yes |
| `UndoKitTests/HistoryReconstructionTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryRecordingTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryRecoveryIntegrityTests.swift` | `CoreData`, `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryRetainedInterfaceTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryRetentionCorruptionTests.swift` | `Foundation`, `SQLite3`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryRetentionTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryScaleTests.swift` | `Foundation`, `ScaleWorkload`, `XCTest` | No |
| `UndoKitTests/HistoryStoreCallbackTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryStoreLifecycleTests.swift` | `Foundation`, `UndoKit`, `XCTest` | Yes |
| `UndoKitTests/HistoryStoreMaintenanceTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryTransactionInterfaceTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryTypedHostTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryTypedHostVersioningTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/HistoryTypedMetadataTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/PersistenceEvidenceHost.swift` | `Foundation`, `UndoKit` | No |
| `UndoKitTests/UndoKitQueueTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `UndoKitTests/UndoKitTests.swift` | `Foundation`, `UndoKit`, `XCTest` | No |
| `prototypes/native/Package.swift` | `PackageDescription` | No |
| `prototypes/native/Sources/NativeProof/main.swift` | `AppKit`, `NativeProofCore` | No |
| `prototypes/native/Sources/NativeProofCore/History.swift` | `Foundation` | No |
| `prototypes/native/Tests/NativeProofCoreTests/HistoryTests.swift` | `Foundation`, `Testing`, `NativeProofCore` | No |
| `prototypes/package/Package.swift` | `PackageDescription` | No |
| `prototypes/package/Sources/PackageProbe/PackageProbe.swift` | `CoreData`, `CryptoKit`, `Foundation` | No |
| `prototypes/package/Tests/PackageProbeTests/PackageProbeTests.swift` | `Foundation`, `Testing`, `PackageProbe` | No |
| `prototypes/recovery/Package.swift` | `PackageDescription` | No |
| `prototypes/recovery/Sources/RecoveryChild/main.swift` | `Darwin`, `Foundation`, `RecoveryProbe` | No |
| `prototypes/recovery/Sources/RecoveryProbe/RecoveryProbe.swift` | `CoreData`, `Foundation` | No |
| `prototypes/recovery/Tests/RecoveryProbeTests/RecoveryProbeTests.swift` | `Foundation`, `Testing`, `RecoveryProbe` | No |
| `prototypes/scale/Package.swift` | `PackageDescription` | No |
| `prototypes/scale/Sources/ScaleChild/main.swift` | `Foundation`, `ScaleProbe` | No |
| `prototypes/scale/Sources/ScaleProbe/HistoryStore.swift` | `CoreData`, `Foundation` | No |
| `prototypes/scale/Tests/ScaleProbeTests/ScaleProbeTests.swift` | `Foundation`, `Testing`, `ScaleProbe` | No |
| `scripts/consumer/DomainIdentity.swift` | `UndoKit` | No |
| `scripts/consumer/HostFixture.swift` | `Foundation`, `Darwin`, `UndoKit`, `ConsumerDomain`, `MachO`, `SwiftUI` | Yes |
| `scripts/diagnostics/coredata-public-import/Package.swift` | `PackageDescription` | No |
| `scripts/diagnostics/coredata-public-import/Sources/CoreDataPublicImportReproducer/ManagedRecord.swift` | `CoreData` | No |
| `scripts/scale/Probe/ScaleProbe.swift` | `Foundation`, `Darwin`, `ScaleWorkload` | No |
| `scripts/scale/ScaleDeviceApp.swift` | `SwiftUI`, `Foundation`, `UndoKit` | No |
| `scripts/scale/Workload/ScaleArtifact.swift` | `Foundation`, `CryptoKit` | No |
| `scripts/scale/Workload/ScaleModel.swift` | `Foundation`, `UndoKit` | No |
| `scripts/scale/Workload/ScaleResources.swift` | `Foundation`, `Darwin` | Yes |
| `scripts/scale/Workload/ScaleWorkload.swift` | `Foundation`, `UndoKit` | Yes |

All Ruby/shell runners (syntax and dependency-use inventory):

- `prototypes/native/run.rb`
- `prototypes/package/run.rb`
- `prototypes/recovery/run.rb`
- `prototypes/scale/run.rb`
- `scripts/assemble-xcframework.rb`
- `scripts/build-scale-device.rb`
- `scripts/build-support.rb`
- `scripts/check-binary-consumer.rb`
- `scripts/check-consumer.sh`
- `scripts/check-documentation-examples.rb`
- `scripts/check-native-consumer.rb`
- `scripts/check-scale-device-evidence.rb`
- `scripts/check-toolchain.rb`
- `scripts/check-undokit-scale.rb`
- `scripts/documentation/site.rb`
- `scripts/documentation/tests/site_test.rb`
- `scripts/maintenance/check-fixtures.rb`
- `scripts/maintenance/check.rb`
- `scripts/release/candidate.rb`
- `scripts/release/candidate_test.rb`
- `scripts/release/fixture.rb`
- `scripts/run-durable-notes-swiftui-ios.rb`
- `scripts/run-durable-notes-swiftui-macos.rb`
- `scripts/run-durable-notes-uikit.rb`
- `scripts/run-durable-notes.rb`
- `scripts/test-package.rb`
- `scripts/test-package.sh`
- `scripts/test-scale-runner.rb`
- `scripts/xcframework/assembly.rb`
- `scripts/xcframework/contract_test.rb`

Resource/project inventory: three Xcode projects and schemes, workspace metadata,
three plists, Project.xcconfig, the unchanged package lock, production Core Data
model/selector and privacy manifest, the standalone diagnostic model, fixture
JSON/text/bundle artifacts and the new DocC SVG. Existing resources are preserved;
XML/plist parsing, checksums and maintained target/resource declarations were
checked. Imported design/research and prototype evidence remain dated records.
