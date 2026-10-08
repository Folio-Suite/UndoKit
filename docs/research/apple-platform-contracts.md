# Apple platform constraints for durable semantic undo

- Status: research evidence for design; no protocol or implementation selected
- Checked: 2026-09-25
- Decision ticket: [Establish Core Data, native undo, and lifecycle constraints](https://github.com/ctwelve/UndoKit/issues/3)
- Map: [Define UndoKit for Folio and KitchenMemory](https://github.com/ctwelve/UndoKit/issues/1)

## Result and evidence boundary

Apple supplies the storage, native command routing, and document coordination
mechanisms needed to investigate this design. It does not supply a documented
transaction joining a host's semantic acceptance with UndoKit's separate history
store, or a failure-aware, persistent native undo stack. Those remain explicit
host/framework contracts to design and prove. A Core Data save, native callback,
or successfully copied database alone cannot certify all three.

This note refreshes KitchenMemory's
[durable storage research](https://github.com/ctwelve/KitchenMemory/blob/23353f56968774cae0f7882f602dd2491e2737a5/docs/research/durable-undo-storage.md)
and [native undo research](https://github.com/ctwelve/KitchenMemory/blob/23353f56968774cae0f7882f602dd2491e2737a5/docs/research/native-undo-facilities.md)
against current Apple documentation and installed SDK declarations. Those earlier
notes supplied leads; the Apple sources below supply platform evidence.

The consumer requirements come from KitchenMemory's
[accepted shared-framework ADR](https://github.com/ctwelve/KitchenMemory/blob/23353f56968774cae0f7882f602dd2491e2737a5/docs/adr/0022-shared-durable-undo-framework.md)
and Folio's
[semantic history contract](https://github.com/Folio-Suite/Folio/blob/135b69515aedb17ea10db87f970257528f7e8ed9/docs/architecture/semantic-history-contract.md).
Both consumer working trees were clean when inspected. This research does not
amend those requirements or audit their implementations.

Labels used below:

- **Documented:** an Apple-published API or behavior contract, with a source.
- **SDK observation:** the declaration/comment present in the identified local SDK.
- **Inference:** a design consequence, recommendation, or missing guarantee; not
  an Apple promise or a settled UndoKit decision.
- **Unproved:** behavior requiring a native experiment. No builds, crash tests,
  migrations, package operations, or native UI prototypes were run for this note.

## Platform and toolchain snapshot

The inspected UndoKit revision was `b94fbbd7685165dbd083ae155375855f848d0845`.
Its [project file](https://github.com/ctwelve/UndoKit/blob/b94fbbd7685165dbd083ae155375855f848d0845/UndoKit.xcodeproj/project.pbxproj)
declares `iphoneos iphonesimulator macosx watchos watchsimulator` for the framework
in both configurations. Mac Catalyst and the designed-for-iPhone/iPad Mac and XR
modes are disabled. Framework deployment targets use Xcode's
`RECOMMENDED_*_DEPLOYMENT_TARGET` variables. These declarations are a platform
baseline, not evidence of successful archives or supported minimum-version
runtime behavior; effective settings and binary distribution have separate
research ownership.

Local tools reported Xcode **27.0 (27A266a)**, Apple Swift **6.4**
(`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), and macOS **27.0 (26A428)**.
`xcodebuild -showsdks` listed macOS, iOS, iOS Simulator, watchOS, and watchOS
Simulator SDKs at **27.0**. `xcode-select -p` resolved to
`/Applications/Xcode.app/Contents/Developer`. SDK inspection references [below](#installed-sdk-evidence)
are reproducible against that installation, not an assertion about older SDKs.

| Platform | Documented or SDK-supported foundation | What is still a host/native proof |
| --- | --- | --- |
| macOS | Foundation `UndoManager`, Core Data, AppKit responder/document integration. | Document-wide ordering across Folio editing contexts; document change counts, versions, save/restore, and text focus. |
| iOS/iPadOS | Foundation/Core Data plus UIKit's responder-based manager; SwiftUI exposes an optional environment manager. | Scene identity across disconnection/relaunch, text priority, actual gestures/keyboard routing, background and force-quit recovery. |
| watchOS | SDK declarations include closure registration from watchOS 2, `NSPersistentContainer` from watchOS 3, and SwiftUI's optional read-only manager from watchOS 6. | Whether the selected watch scene supplies a manager; what host controls invoke undo; actual suspension/relaunch behavior. Do not infer UIKit's text or gesture routing from Foundation availability. |

Sources: [Core Data stack availability](https://developer.apple.com/documentation/coredata/setting-up-a-core-data-stack-manually),
[Foundation manager](https://developer.apple.com/documentation/foundation/undomanager),
[UIKit responder manager](https://developer.apple.com/documentation/uikit/uiresponder/undomanager),
[SwiftUI environment](https://developer.apple.com/documentation/swiftui/environmentvalues/undomanager),
and SDK observations S1–S5 below. No tvOS, visionOS, or Catalyst promise is added
merely because the underlying APIs also exist there.

## Core Data saves and independent acceptance

**Documented:** saving a managed object context commits one level up. A child
context save changes its parent context; persistence requires saving through the
context attached to the coordinator. Store loading has a completion/error result
for each store. An incomplete-save error can identify stores or objects that
failed. These are observable outcomes to preserve, not grounds to equate every
save error with one particular domain outcome.
[Context save](https://developer.apple.com/documentation/coredata/nsmanagedobjectcontext/save()),
[store loading](https://developer.apple.com/documentation/coredata/nspersistentcontainer/loadpersistentstores(completionhandler:)),
[incomplete save](https://developer.apple.com/documentation/coredata/nspersistentstoreincompletesaveerror).

**Inference:** no reviewed API documents a commit spanning independent host and
UndoKit coordinators, arbitrary host persistence, and package resources. A shared
directory, common queue, or one enclosing native undo group does not establish
that guarantee. Do not claim either that all Core Data multi-store saves are
necessarily partial or that they provide this application transaction. The
separate-store design must work without either assumption.

Consider three conceptual boundaries, without prescribing their API or schema:

| Interruption boundary | What the recovery design must distinguish |
| --- | --- |
| Before durable preparation | No recoverable request may exist yet; define whether any host mutation was allowed. |
| Preparation saved, host acceptance unknown | The request may be pending, rejected, accepted, or unresolved. A missing history finalization is not proof of rejection. |
| Host accepted, history finalization missing | Discover the already accepted outcome and repair history without another domain effect. |
| Inverse accepted, native/history transition incomplete | Avoid applying the inverse twice or advertising a Redo that describes a different accepted outcome. |
| Invalidation selected but its save failed | In-memory stack clearing cannot prevent old durable entries from appearing at the next open. |

These are **inferences** from the independent persistence boundaries and the
consumer contracts, not an implemented two-phase commit. Stable request identity,
authoritative outcome discovery, and duplicate-free recovery are necessary
questions. If a host proposes an acceptance receipt, it must establish how that
receipt and the accepted domain effect become recoverable together; a third
independent best-effort write merely moves the uncertainty.

KitchenMemory already requires a distinction between ordinary interruption and
a reported failed/rejected inverse. It also requires preserving pending
compensation and preventing invalidated actions from returning after a failed
invalidation write. The platform APIs do not choose the fallback. Candidate
designs must establish sufficient durable host evidence or independently
revalidate/quarantine affected history on reopen. If outcome evidence is absent,
neither blindly retrying nor assuming rejection is justified. Exact evidence
retention, quarantine scope, and recovery UX remain decisions.
[Accepted KitchenMemory recovery requirements](https://github.com/ctwelve/KitchenMemory/blob/23353f56968774cae0f7882f602dd2491e2737a5/docs/adr/0022-shared-durable-undo-framework.md).

**Documented:** Core Data contexts and their managed objects are confined to
their context queues. Private contexts use `perform`/`performAndWait`; managed
object references should not cross queues. Object IDs can identify an object to
another context. **Inference:** the API needs an intentional handoff between
main-actor native routing, history persistence, and the host's acceptance
executor. Main-actor isolation alone does not serialize another scene, process,
or domain store. Lock ordering and reentrancy are proof obligations.
[Core Data concurrency](https://developer.apple.com/documentation/coredata/using-core-data-in-the-background).

Core Data's **persistent history tracking** records store transactions and
insert/update/delete changes, with tokens for consumption. It can help observe
interference. It does not define host inverse semantics or Folio's branching
document history. Similarly, a context's automatic object undo is a separate
facility from accepted semantic compensation. Attaching UndoKit's bookkeeping
context to a user's native manager would need a deliberate justification; it
must not expose history-record maintenance as user undo.
[Persistent history](https://developer.apple.com/documentation/coredata/persistent-history),
[consuming changes](https://developer.apple.com/documentation/coredata/consuming-relevant-store-changes),
[context undo manager](https://developer.apple.com/documentation/coredata/nsmanagedobjectcontext/undomanager).

## Native execution, failure, and restoration

| Documented behavior / SDK observation | Design implication, not a selected adapter |
| --- | --- |
| `UndoManager` and its Swift handler are `MainActor`-isolated. The handler returns `Void`, with no throwing or asynchronous acceptance result. S1–S2. | A native callback returning does not establish domain acceptance. A deferred task finishes outside the callback's undo/redo registration context. Synchronous durable acceptance and asynchronous pending-operation designs need different proofs. |
| Groups are the unit of undo. Registrations during undo form redo; new ordinary registrations clear ordinary redo. Automatic grouping is enabled by default around run-loop passes. | A UI event/group is not a semantic transaction. Do not leave a group open across arbitrary asynchronous work or assume multiple callbacks are atomically accepted. Preserved branches are separate durable history. |
| `canUndo` means actions exist, not that invocation is immediately safe: open groups can matter. `undo()` can raise when multiple groups remain open. | Recheck host eligibility at acceptance. Native menu validation cannot establish domain safety after interference. |
| Removal is all actions or actions for a target; the public surface does not offer removal by arbitrary semantic predicate or reinsertion at a saved stack position. | Target granularity affects invalidation. Clearing an entire manager may erase native text history; one shared adapter target removes all of that target's registrations. |
| Closure registration does not strongly retain its target. Captures can retain other objects. | Define adapter lifetime and teardown so restored or delayed callbacks cannot mutate a retired document/scene/scope. |
| `levelsOfUndo` bounds native top-level groups, with zero meaning unlimited. S1. | Setting it to 100 is not a durable history retention, payload lifetime, or recovery-evidence policy. |

Sources: [handler registration](https://developer.apple.com/documentation/foundation/undomanager/registerundo(withtarget:handler:)),
[undo architecture](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/UndoManager.html),
[grouping](https://developer.apple.com/documentation/foundation/undomanager/groupsbyevent),
[availability](https://developer.apple.com/documentation/foundation/undomanager/canundo),
[undo invocation](https://developer.apple.com/documentation/foundation/undomanager/undo()),
[all-action removal](https://developer.apple.com/documentation/foundation/undomanager/removeallactions()),
[target removal](https://developer.apple.com/documentation/foundation/undomanager/removeallactions(withtarget:)),
and S1–S2. The archived architecture explains stack behavior; the installed
declarations corroborate its still-public mechanisms.

**Inference:** a failed callback cannot return rejection to Foundation or ask it
to restore a consumed group transactionally. The adapter must deliberately
reconcile its projection with accepted host outcomes. Registering an inverse
before knowing acceptance risks false Redo; registering it later is not the
documented in-progress undo registration mechanism. A notification that undo
finished is not a domain acceptance receipt.

**SDK/API observation:** the reviewed public `UndoManager` surface provides no
serialized stack or direct stack-import API. Registration can install callbacks
without invoking domain edits, but reconstructing an arbitrary Undo-and-Redo
position is not documented as a built-in restoration operation. Proxy
registration or a custom projection may be feasible; no algorithm is chosen or
verified here. Do not replay historical domain mutations merely to manufacture
native stack state.
[Public API](https://developer.apple.com/documentation/foundation/undomanager),
S1–S2, and the accepted consumer contracts.

**Additional Folio constraint:** `NSDocument` observes undo-manager notifications
to update change tracking (S6). Its default revert implementation clears native
undo after reading the saved contents (S6). `UIDocument` also connects undo
notifications to change counting. Therefore a reconstruction proof must show no
spurious edited indicator, autosave, or domain change, as well as correct command
names and availability. Folio's requirement to retain displaced history during
Document Version restoration is behavior the host must establish around the
native lifecycle; default revert does not implement that semantic contract.
[NSDocument manager](https://developer.apple.com/documentation/appkit/nsdocument/undomanager),
[UIDocument manager](https://developer.apple.com/documentation/uikit/uidocument/undomanager),
[Folio restoration contract](https://github.com/Folio-Suite/Folio/blob/135b69515aedb17ea10db87f970257528f7e8ed9/docs/architecture/semantic-history-contract.md).

## Ownership, focus, and mobile lifecycle

AppKit routes manager requests through responders; a window can use its
delegate's manager, and text views can have a delegate-supplied manager. UIKit
finds the nearest manager in the responder chain; its documented `UITextField`
example has a separate manager cleared on resignation. SwiftUI's environment
value is optional and read-only; unsupported environments yield `nil`.
[AppKit integration](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html),
[UIKit routing](https://developer.apple.com/documentation/uikit/uiresponder/undomanager),
[SwiftUI contract](https://developer.apple.com/documentation/swiftui/environmentvalues/undomanager).

**Inference:** durable history belongs to a host-supplied identity, not a native
manager object's lifetime. Folio's document ordering and KitchenMemory's logical
scene plus owner/store/Kitchen boundary are intentionally different. Attaching a
new view or manager is not permission to merge histories. Reattachment requires
scope, outcome, and eligibility checks before native availability becomes true.
Localized labels should describe accepted user intent; exact presentation is
owned by the host/native integration.

UIKit may disconnect a background/suspended scene to reclaim resources, and the
termination callback is generally unavailable for a suspended app's termination.
Background runtime extensions expire. watchOS likewise permits purging suspended
apps and grants only limited background execution. Persist during operation
processing; lifecycle callbacks are extra opportunities to finish or quiesce,
not the sole durability boundary. A forced termination must be recoverable
without a final callback or a scheduled future task.
[UIKit scene lifecycle](https://developer.apple.com/documentation/uikit/managing-your-app-s-life-cycle),
[termination callback](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/applicationwillterminate(_:)),
[background time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time),
[watchOS lifecycle](https://developer.apple.com/documentation/watchkit/life-cycles).

Core Data exposes file-protection policy; complete protection prevents file
reads/writes while a device is locked or booting. **Inference:** protected-data
unavailability must not become “empty history” or corruption. The selected
mobile policy needs a device-lock recovery case without weakening the host's
protection requirements.
[Store protection](https://developer.apple.com/documentation/coredata/nspersistentstorefileprotectionkey),
[complete protection](https://developer.apple.com/documentation/foundation/fileprotectiontype/complete).

## Package save, copy, restore, and omission

**Documented:** with SQLite WAL, committed data can remain in the `-wal` file
after a context save. Copying only the main database may lose transactions.
Apple's archived QA1809 recommends Core Data-aware operations, or handling the
main store and WAL together as a package. It does not prove a concurrent copy of
the containing directory is a coherent application snapshot.
[WAL and backup guidance](https://developer.apple.com/library/archive/qa/qa1809/_index.html).

**SDK observation:** coordinator replacement honors SQLite locks, journals, and
journaling modes (S3). Migration changes the store location/type and removes the
original attachment from the coordinator. Destroy uses store-aware behavior;
it is not a safe instruction to unlink an open database. These operations manage
a store, not all host content and dependencies in a document package.
[Store replacement](https://developer.apple.com/documentation/coredata/nspersistentstorecoordinator/replacepersistentstore(at:destinationoptions:withpersistentstorefrom:sourceoptions:type:)),
[store migration](https://developer.apple.com/documentation/coredata/nspersistentstorecoordinator/migratepersistentstore(_:to:options:type:)), S3.

`NSFileCoordinator` coordinates operations among participating presenters and
processes. `NSDocument` incorporates file coordination and can save into a
temporary location different from its current `fileURL`. **Inference:** UndoKit
must cooperate with the host's document save/move lifecycle; keeping an open
database connection to an old package path through replacement needs an explicit
rebind/reopen strategy. Neither coordination nor a directory replacement creates
a domain/history acceptance transaction by itself.
[File coordination](https://developer.apple.com/documentation/foundation/nsfilecoordinator),
[NSDocument saving behavior](https://developer.apple.com/documentation/appkit/nsdocument), S6.

For an iOS host using file presenters, Apple also documents removing presenters
while backgrounded; `UIDocument` handles that lifecycle itself. Coordinated
access can receive cancellation before access, or expire after background time.
Do not add an independently long-lived presenter without identifying ownership.
[File presenter and background rules](https://developer.apple.com/documentation/foundation/nsfilecoordinator).

The package contract consequently needs **proof**, rather than an assumed
filesystem recipe, for all of these cases:

- Ordinary save and copy contain matching generations of current content,
  history, and required external resources, including outstanding journal data.
- Save As/move/replacement leaves the live stack attached to the intended store,
  without aliasing histories accidentally between independent documents.
- Checkpoint or native-version restore retains displaced history as Folio
  requires, even though the restored package may contain an older history store.
- Omission stages a current-content-preserving result, commits it successfully,
  then clears the appropriate live histories. A failed save must leave existing
  durable history intact. Deleting the source history before success violates
  Folio's contract.
- Recording Off, explicit removal, and one-time omission remain separate host
  policies. Omission does not erase other native versions, backups, or exports.

These are consumer requirements and design implications, not guarantees of a
particular Core Data or `NSDocument` call.
[Folio history settings and omission](https://github.com/Folio-Suite/Folio/blob/135b69515aedb17ea10db87f970257528f7e8ed9/docs/architecture/semantic-history-contract.md).

## Migration and unreadable history

Lightweight migration needs discoverable source/destination models and inferable
changes. Staged migration requires versioned models and ordered migration stages.
The installed SDK exposes distinct incompatible-version, missing-model,
source/destination, cancellation, and other migration errors (S7).
[Automatic migration](https://developer.apple.com/documentation/coredata/migrating-your-data-model-automatically),
[staged migration](https://developer.apple.com/documentation/coredata/staged-migrations).

**Inference:** model compatibility, host payload compatibility, and semantic
eligibility are three separate checks. A store migrating successfully does not
make an old inverse executable. An unavailable or failed-to-open store must
remain distinguishable from a successfully opened empty one. Automatic migration
can write during opening; “we only opened it” is not a preservation strategy.
Preserving recoverable evidence may require a coordinated store-aware snapshot
before migration and a deliberate policy for failed/unsupported versions. Exact
backup, read-only access, repair, and fallback editing behavior remain decisions;
never silently delete and recreate unknown history.
[Migration options](https://developer.apple.com/documentation/coredata/nsmigratepersistentstoresautomaticallyoption),
[load error contract](https://developer.apple.com/documentation/coredata/nspersistentcontainer/loadpersistentstores(completionhandler:)),
[KitchenMemory preservation requirement](https://github.com/ctwelve/KitchenMemory/blob/23353f56968774cae0f7882f602dd2491e2737a5/docs/adr/0022-shared-durable-undo-framework.md).

## Precise experiments to select after the contracts settle

These questions can become disposable prototype tickets. They are not proof
already obtained, and they do not preselect the implementation under test.

| Experiment question | Minimum setup and observable pass condition |
| --- | --- |
| Can two-store recovery distinguish every interrupted outcome? | One host command with stable identity and durable outcome lookup. Terminate before/after preparation, host acceptance, and finalization; repeat during inverse and retry. Inject failed saves. Reopen: exactly one accepted domain effect, no entry for rejection, and unknown outcomes remain unavailable until reconciled. |
| Can failed invalidation remain invalid after relaunch? | Persist eligible history, cause a host invalidation, fail its history-store write, terminate, and reopen. No affected Undo/Redo reappears. Explain the durable evidence that makes that result possible, including if another write also fails. |
| Can native Undo and Redo be reconstructed without mutations or false success? | Persist a position with both directions available; reopen into an instrumented native document/scene. Observe zero domain handler applications during restoration, correct ordering/names/groups, and unchanged document dirty state. Then exercise successful, rejected, save-failed, and deferred compensation. Never expose Redo for an unaccepted inverse. |
| Can native focus coexist with durable semantic scope? | Two Folio editing contexts and two KitchenMemory scenes, including focused text and non-text controls. Observe correct recipient, logical scope, grouping, teardown, interference response, and relaunch ownership. Exercise actual menu/keyboard/mobile controls rather than direct method calls alone. |
| Can package generations survive real document operations? | A document with domain content, history, and resources, with committed data still in WAL. Exercise save, copy, Save As/move, native version restore, and omission under active contexts. Fail staging/replacement. Reopen each result and verify matching generations, restored branches, source preservation on failure, and intended live stack attachment. |
| Can compatibility failures preserve useful recovery evidence? | Fixtures for every supported schema and payload version, plus future/unknown schema, missing model, and damaged/unavailable store. Fail/interrupt migration. Confirm the source remains available for the agreed recovery path and an explicit unavailable state never becomes a silent empty store. |
| Does the selected lifecycle contract hold on every declared family? | Native macOS/iOS/iPadOS/watchOS hosts; background, scene disconnect where supported, process kill, device lock, and ordinary relaunch. Confirm real watch manager availability/routing and avoid depending on termination callbacks. Simulator and device observations must be recorded separately. |

Large-history timing, memory budgets, and branch traversal remain separate design
questions. These platform sources do not establish acceptable Folio history size
or an end-to-end latency bound for synchronous durable native Undo.

## Installed SDK evidence

The following paths are relative to
`/Applications/Xcode.app/Contents/Developer/Platforms/` and record inspected
declarations rather than framework implementation. They can be located with
`rg` by symbol if line numbers change in another SDK.

| Ref | SDK file and inspected evidence |
| --- | --- |
| S1 | `MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSUndoManager.h`, lines 34–170: actor annotation, grouping, levels/counts, availability, removal, and callback declaration. `WatchOS.platform/Developer/SDKs/WatchOS27.0.sdk/.../Foundation.framework/Headers/NSUndoManager.h`, lines 36 and 170, corroborates watch availability. |
| S2 | `MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/Foundation.framework/Modules/Foundation.swiftmodule/arm64e-apple-macos.swiftinterface`, line 18032: generic `registerUndo` has a main-actor handler returning `Void`, without `async` or `throws`. |
| S3 | `MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/CoreData.framework/Headers/NSPersistentStoreCoordinator.h`, lines 302–321: migration attachment, store-aware destroy/replacement, and coordinator queues. Lines 165–169: store protection and persistent-history option. |
| S4 | `WatchOS.platform/Developer/SDKs/WatchOS27.0.sdk/System/Library/Frameworks/CoreData.framework/Headers/NSPersistentContainer.h`, line 21: platform availability including watchOS 3. |
| S5 | `WatchOS.platform/Developer/SDKs/WatchOS27.0.sdk/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64_32-apple-watchos.swiftinterface`, lines 21340–21344: read-only optional environment manager, watchOS 6 availability. |
| S6 | `MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/AppKit.framework/Headers/NSDocument.h`, lines 226–230: default revert clears undo; lines 693–699: manager notification/change-count integration; document activity/file-access comments around lines 165–215: sequencing and deadlock cautions. |
| S7 | `MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/CoreData.framework/Headers/CoreDataErrors.h`, lines 62–89: incomplete-save and migration error distinctions. `NSManagedObjectContext.h`, lines 77–106 and 162: queue types, perform APIs, manager property, and fallible save. |

No claim here depends on private APIs or inferred Foundation/Core Data internals.
The required native experiments remain open; source inspection establishes what
the design must accommodate, not that UndoKit already satisfies it.
