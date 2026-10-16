<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Release qualification

The maintainer-approved [2026-10-15 amendment](https://github.com/Folio-Suite/UndoKit/issues/57)
and [ADR 0007](adr/0007-os-behavioral-qualification.md) distinguish CPU build
coverage from OS behavioral execution. They replace the blanket Intel/physical
hardware procurement requirements in the earlier [platform](https://github.com/Folio-Suite/UndoKit/issues/5)
and [acceptance](https://github.com/Folio-Suite/UndoKit/issues/8) resolutions.
Historical reports retain their original measured meaning.

## Architecture acceptance

Under the current high-level Swift/Cocoa and Core Data constraints, clean local/CI
builds covering the declared architectures, inspected artifacts and independent
consumers are sufficient architecture acceptance evidence. Dedicated Intel Mac
and Intel simulator execution are waived. Record this as maintainer policy
acceptance, not an Intel runtime pass. A green CI status without the relevant
builds does not establish architecture coverage.

The matrix remains macOS 14 arm64/x86_64, iOS/iPadOS 17 device arm64 and separate
simulator arm64/x86_64 products. Keep the pinned Xcode/Swift toolchain, Swift 6,
complete concurrency checking and existing compiler/ABI limits. Inspect every
required variant, interface, resource, deployment declaration and per-architecture
binary/dSYM UUID pairing.

## OS and behavioral execution

Run the applicable production suite on the declared floor and selected current
macOS and iOS/iPadOS runtimes. CI runners, simulators, VMs or hardware may provide
that execution; record exact OS/build and toolchain versions and cover iPhone/iPad
native differences where relevant. Missing OS execution remains open. The
environment inventory still tracks OS access and specific physical questions.

Keep the existing public seams: production APIs with durable host state and
authoritative receipts, installed independent consumers, and source-bound
artifact/documentation checks. Retain Debug/Release coverage where applicable;
Debug-only failure injection does not become a Release requirement. Retain:

- History Transaction/Undo Group atomicity, retained-history reconstruction,
  retention safety, unsupported-store refusal and preserved originals.
- Production-boundary failures, recovery/reconciliation, correct Suspension,
  and no partial groups or duplicate host effects.
- Package/native/binary consumers, shared macOS installation, bundled resources,
  close/reopen and one runtime per process.
- Native Undo/Redo, text grouping/marked text, focus, pending/rejection,
  window/scene isolation and applicable lifecycle/storage/file-protection behavior.

Portable behavior need not be multiplied by every CPU and packaging combination.
Compilation cannot replace these behavioral observations.

## Physical questions and scale

Require hardware for a specific unresolved behavior that available simulation,
virtualization or runners cannot adequately answer. Record the question, why
hardware is necessary, intended evidence and result/limitation. A required
physical file-protection or input interaction remains blocking until demonstrated
or explicitly revised by the maintainer. Waiving a device inventory does not
waive the behavior itself.

Keep the production 10,000-group Mac/iOS fixtures, independent expected-state
checks, three deterministic repetitions and ten fresh-process reopen measurements.
Appropriate simulation/virtualization may establish portable correctness when
the complete fixture executes with suitable predeclared resource budgets.
Report latency, memory and storage in the measured environment without inferring
physical-device performance. Numerical timing targets and larger workloads remain
advisory; controlled resource refusal and ordinary responsiveness remain mandatory.

The [scale protocol](production-scale.md) describes current runners. Its physical
checker still requires physical evidence; simulator smoke is neither a full
fixture pass nor a physical pass. Work needed to execute the complete iOS fixture
in another accepted environment remains under #27. This policy changes no runner
output and relabels no historical result.

## Evidence and candidate identity

Distinguish architecture build acceptance, actual behavioral execution, maintainer
waivers, missing evidence and advisory measurements. Bind results to exact
source/candidate, manifest/ZIP hashes, route, configuration, toolchain and
environment. Historical prototypes do not qualify current production behavior.

Signing, archive/export/launch, useful symbolication, compiled examples,
DocC/link/license checks, hosted documentation and exact candidate approval remain
separate gates. Abrupt termination remains unqualified. This policy does not
authorize publication.

Keep candidate bytes/manifests unchanged. Qualification-relevant source or release
documentation changes require a new candidate identity and applicable requalification.
A separate readiness record may reference the amended policy; it must not rewrite
old evidence or an immutable candidate.

## Future releases

Clean declared-architecture builds plus applicable OS behavioral/native tests
are the default while these constraints hold. Reassess before work below Swift,
CPU-specific/low-level optimizations or cross-process binary formats, and
substantial storage, recovery or platform-lifecycle changes even in Swift.
Record the risk and resulting coverage decision.
