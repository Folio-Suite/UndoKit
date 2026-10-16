<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Shared History Session interface

This is the implementation design for [ADR 0007](adr/0007-shared-native-history-coordination.md),
accepted through the architecture review on 2026-10-15. It consolidates ordinary
application editing around one History Session and typed operation handles.
The declarations below illustrate responsibilities; they are not shipped symbols.
Backward compatibility is not required before shipping, including public
declarations and pre-release persisted formats. Folio and KitchenMemory will
conform after the interface stabilizes. Do not add legacy adapters, old-format
readers or migrations for this refactor. Current-format data preservation, host
authority and durable recovery remain required.

## Ordinary integration

The application establishes ownership once, registers its operation families,
and gives editing code typed handles and presentation attachments:

```swift
let session = history.open(configuration, host: documentAdapter)
let noteEdits = session.commands(for: noteOperation)
let windowHistory = session.attach(owner: windowController)

await noteEdits.submit(.rename(noteID, to: title))

// The app's document, window or responder provides this manager.
windowHistory.undoManager
```

An operation declaration binds a stable family identity, current Command and
effect codecs, canonical Intent Fingerprint construction, and actor-correct host
delivery and outcome lookup. Define those facts once. Ordinary submission must
not repeat the registration or require an encoded payload, explicit retry
identity, checkpoint-state codec or whole-document snapshot.

The host can use an enum for a family, or define separate families. Mixed-family
atomic Undo Groups still require one host-owned atomic execution and matching
outcome lookup; separate successful callbacks cannot establish atomicity.

Native text bindings use the same typed handles. A binding maps a field's value
and opaque authoritative revision to a Command. UndoKit owns capture ordering,
draft journaling, composition tracking, settlement and authoritative refresh.
Equal values do not establish equal revisions. Checkpoint and reconstruction
support is a separate capability, not a prerequisite for ordinary Commands.

Field journals bind scope, working identity, generation, stable field and mapping
identity, codec/version, base value/revision, captured intent and exact prepared
Command. Define the new journal format directly; no version-1 whole-draft reader,
migration or parallel journal implementation is required. Unknown formats fail
explicitly rather than being mistaken for valid current-format recovery evidence.

## Ownership and locality

| Owner | State and obligations |
| --- | --- |
| Application-owned session collection | Retain opening, active, closing and blocked sessions; arbitrate scope ownership and shared physical stores |
| History Session | One admission queue, recovery ownership, History Generation fencing, draft settlement and coherent status for one scope |
| Host adapter or domain lease | Domain resources, semantic validation, atomic effects and receipts, canonical intent, reconstruction and application policy |
| Presentation attachment | Weak presentation ownership, observation and native routing; no history-store or recovery ownership |
| Platform adapter | Actual AppKit/UIKit control behavior, live-manager mechanics and native registration classification |

Scope ownership is qualified by the working history-store identity. Multiple
windows share the same session. Explicit independent copies have distinct working
identities; incidental URL spelling must not establish a second writer.
Conflicting registrations or ownership requests fail explicitly rather than
replacing a live host. Physical writer ownership remains enforced across processes.

Retain the owner and any host lease before asynchronous acquisition starts.
Opening may expose an inspectable opening or blocked session; it must never throw
away partially acquired resources. Opening recovery counts as active work.
Close requested during opening is monotonic: a later acquisition completion
cannot restore readiness or release persistence while a callback still uses it.

The framework closes its history resources before releasing host ownership.
Closure reports unprepared queued requests as unexecuted and safeguards active
work under the existing [store lifecycle contract](store-lifecycle-contract.md).
Durably preserved unresolved work can survive successful closure. Failure to
safeguard required evidence retains the responsible owner. Disappearing or
rebuilding a window only detaches or attaches a presentation.

## Ordering, failure and isolation

One internal admission owner governs typed submission, native settlement,
durable Undo/Redo, recovery and mutating advanced capabilities. Do not put another
independent FIFO in front of the existing transaction queue. A presentation or
host must not coordinate two queues or duplicate the session's busy state.

Reserve an ordinary submission's position and capture its generation before
asynchronous encoding can reorder it. Preserve admission order, not an inferred
wall-clock ordering among independent tasks. Charge reservations against the
bounded queue and validate encoded size before durable preparation. Capacity
failure is explicit and occurs before host delivery; initial limits remain
configurable under the existing measurement contract.

Commands and host values retain their declared actor isolation. Ordinary handles
that cross actors accept transferable values. Actor-local typed access preserves
non-Sendable values by encoding on the owning actor and passing only bounded
encoded data across the seam. No unchecked sendability, type-name-based durable
identity or arbitrary queued mutation closures are acceptable shortcuts.

Transferability alone does not freeze intent. The host captures stable intent
before suspension, including when an actor-local Command refers to mutable
objects. A registration binds the actual handler and operation, not merely a
Swift value type. Every reserved slot reaches exactly one terminal result.
Late encoding completions carry a reservation identity and session epoch and
cannot revive work already reported as unexecuted. Preserve same-scope host
callback reentry rejection to prevent a callback awaiting its own FIFO head.

A preceding live editing transaction settles before a semantic request is
delivered. Rejection of that prerequisite stops the dependent invocation; it
cannot fall through to an older Undo Group. An ordinary independent Command's
proved rejection does not imply that later Commands are invalid: the host still
validates each request. Operations that must succeed together use atomic groups.

While ordinary durable work waits or executes, native editing and native
Undo/Redo are blocked. Existing marked-text composition must remain able to
finish; it is never forcibly committed or stranded by the admission barrier.
Only one live native editing transaction participates in a scope at a time,
consistent with [ADR 0006](adr/0006-uikit-live-and-durable-undo.md). Focus transfer
settles that transaction before admitting another editor, including another window.

Cancellation removes still-waiting work. After durable preparation, apply the
existing preparation and delivery cancellation rules; cancellation cannot erase
possible host effects. An uncertain outcome or incomplete finalization stops
further delivery and completes still-queued requests explicitly as unexecuted
with recovery required. They never resume automatically after reconciliation.
The framework retains the exact identity and evidence of the active transaction.

The public result must distinguish an unexecuted request from a delivered request
with an unresolved outcome. Swift case names are implementation choices; an
ambiguous failure that makes callers guess whether delivery occurred is not.

An accepted transaction receipt and presentation readiness are distinct. Failed
authoritative refresh can leave a session blocked after acceptance. Session
status governs editing admission. Status supports multiple observers without
one window replacing another window's callback. Retired attachments, handles
and asynchronous completions cannot act on a replacement session or generation.

Use an attachment registry and explicit live-transaction identity. Removing the
current single-connection guard is insufficient: capture, presentation and
settlement callbacks are currently singular. Passive presentations receive
authoritative updates without overwriting the active draft. Settlement can retire
only the matching transaction's known live work, never a newer editor's stack.

## Native and advanced seams

Supply UndoKit's UndoManager through the app's normal native routing. AppKit's
recognized editor/text-storage registrations still need forwarding to a dedicated
live manager. UIKit retains its proved original-manager route. The shared module
owns editing-transaction policy; native adapters own the actual platform mechanics.
Preserve unknown callback graphs and block the affected integration until explicit
reconciliation. Acceptance, window detachment and live-stack retirement cannot
silently discard those callbacks. Local scratch editors retain isolated local Undo.

Focused reading, retention, recovery, lifecycle and opaque transaction capabilities
reach the same session owner when used alongside ordinary editing. They cannot
expose an unfenced engine underneath an active session. A fully lower-level
integration may own its scope directly, but cannot create a competing owner for
the same working scope. Store-wide copy or maintenance fences every affected scope.

Host authoritative receipts, opaque payload meaning and resource policy remain
under [ADR 0003](adr/0003-host-adaptation-module-ownership.md). Retention Holds and
Recovery Plan protection remain under [ADR 0002](adr/0002-retained-history-module-ownership.md).
Simplifying ordinary access must not remove these capabilities.

## Source navigation

Use folders to reveal the two access paths and shared host configuration. This
layout does not introduce more Swift products or runtime identities:

```text
Interface/
  common identities, results, failures and policy values
  Application/
    session collection, History Session, typed handles, attachments
    AppKit/
    UIKit/
    SwiftUI/
  Hosting/
    typed host contracts, operation declarations and codecs
  Advanced/
    Transactions/
    RetainedHistory/
    Storage/
```

Folder spelling may follow the final declarations. `Hosting/` is shared setup,
not another editing route. The DocC landing page and examples should teach ordinary
setup and submission first, with advanced access linked separately. Substantive
implementation remains in `Modules/`. Preserve the single dynamic package product
required by [ADR 0004](adr/0004-independent-source-package.md).

## Implementation sequence and acceptance

1. **Repair the two reproduced correctness defects.** Protect opening recovery
   from concurrent store closure, and unify rejected inverse invalidation for
   retained and recording-off Undo Groups. Preserve an invalidation barrier;
   deleting the rejected group must not make older groups traversable without
   the required independence proof. Keep these changes independently
   reviewable and verify them through existing public transaction/store access.
2. **Establish one session and admission owner.** Bring opening, queueing,
   recovery, maintenance and complete closure behind that owner. Add typed handles
   through the existing host-adaptation seam. Preserve actor isolation and test
   ordering across delayed encoding, cancellation, generation changes and Q8's
   explicitly unexecuted queue results.
3. **Consolidate native coordination and lifetime.** Move shared editing rules,
   presentation observation and weak ownership out of platform-specific wrappers.
   Add multiple attachments, field-level drafts and framework-owned history
   resources. Replace the router/session overlap and remove framework store and
   engine bookkeeping from ordinary host leases.
4. **Converge every supported caller.** Migrate repository examples and independent
   consumers, organize `Interface/`, and update DocC and integration contracts.
   Remove superseded orchestration and obsolete tests only after equivalent
   behavior is covered through the new interface. Folio and KitchenMemory adapt
   after this interface stabilizes.
5. **Qualify the changed candidate.** Follow [CONTRIBUTING](../CONTRIBUTING.md):
   Debug/Release package checks and independent package/native consumers on macOS
   and an installed iOS simulator. Repeat affected native interaction checks for
   AppKit, UIKit and SwiftUI. Keep physical IME/device, floor-OS and Intel evidence
   limitations explicit. Earlier source/runtime evidence does not qualify a new
   candidate.

The interface is the test surface. Preserve real temporary-store tests for
preparation, authoritative receipts, interrupted finalization, reopen and original
data. Use deterministic native adapters to exercise shared coordination, and real
native controls for registration, composition, focus, menus and teardown. Preserve
retention/resource protections while reorganizing access. A build or method-call
probe alone cannot establish installed native behavior.

| Existing tests | Carry forward |
| --- | --- |
| `UndoKitQueueTests`, `HistoryStoreCallbackTests`, `HistoryStoreLifecycleTests`, `HistoryStoreMaintenanceTests` | FIFO, cancellation, callback reentry, close across scopes and maintenance exclusion; add delayed opening and Q8 queue completion |
| `HistoryRecordingTests` | Recording transitions, transient inverses and resource protection; add rejected Undo/Redo and invalidation barriers |
| `HistoryTypedHostTests` and metadata/integrity tests | Actor isolation, family routing, atomic group evidence, current codec identity and member order; older-version tests are not a compatibility gate |
| `NativeHistorySessionTests`, `NativeHistoryRouterTests` | Replace obsolete busy/flag choreography with shared-session outcomes; preserve journals, recovery, composition, weak ownership and stale-completion scenarios |
| Retained-interface, reconstruction, corruption and persistence-failure tests | Recovery Plan lifetime, retention/resource protection, real save failures and preserved original evidence |

In particular, the session test that expects an independent semantic submission
to return busy during native Undo must instead verify queueing and explicit
unexecuted completion on close or uncertainty. Do not retain competing behaviors
behind compatibility wrappers.

No additional runtime package is required by this design. Keep Apple framework
mechanisms where they fit; evaluate Swift Collections only against measured queue
workloads rather than adding a dependency solely to replace a bounded array.
