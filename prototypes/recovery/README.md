<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Disposable UndoKit recovery proof

This is the bounded on-disk acceptance and recovery probe for
[#47](https://github.com/Folio-Suite/Folio/issues/47). It is throwaway evidence,
not the production UndoKit engine or a proposed public API. Its baseline is
`52c498fcf7dc50b5c060820f217c957db74355f7`, containing the accepted #41–#46
contracts. Keep this prototype on its evidence branch rather than merging it
into the shipping framework.

The question is whether separate host and history stores can preserve exactly
one accepted effect, correct Undo/Redo availability and recovery evidence when
execution stops between their commits.

## Run

```sh
ruby UndoKit/prototypes/recovery/run.rb
```

Run from the repository checkout on macOS with Xcode selected. The runner builds
the independent Swift package using Swift 6 strict concurrency and warnings as
errors, then runs the behavioral suite and its SIGKILL children. The small suite
uses a 180-second default timeout, 2 GiB process-group memory limit, 12 GiB owned
disk limit and 20 GiB free-space floor. No budget override was used in the
recorded run. See [results](results.md) for evidence and remaining coverage.

## Accepted seams and ownership

Tests observe submission, authoritative host outcome lookup, reconciliation,
reopening, host semantic state and history availability. Diagnostic transition
controls and failure hooks exist solely to stop this probe at exact boundaries.
Hosts of the eventual production interface do not drive internal history states.

The host owns semantic changes and commits a receipt with its effect. UndoKit's
probe owns its separate Core Data history records, ordering and finalization.
No distributed transaction joins the stores. Missing outcome evidence is
Unresolved, never proof of rejection. Accepted effects are finalized without
reapplying them. A rejected inverse must persist invalidation before later
availability becomes visible.

## Proof obligations

| Boundary or behavior | Required observation |
| --- | --- |
| Preparation failure | Host state unchanged; no accepted Action |
| Prepared, never delivered | Recovery can prove the host was not invoked; cancellation leaves no effect |
| Delivery may have begun | Authoritative lookup precedes any possible retry; unknown outcome suspends the scope |
| Host accepted, history not finalized | Exact host effect retained; finalization only; no duplicate application |
| Rejected ordinary Command | No effect and no Action |
| Accepted inverse | Whole-group compensation and immutable history relationship; no premature Redo |
| Rejected inverse with failed invalidation | Durable recovery fence; no stale Undo/Redo after reopening |
| Exact retry / conflicting fingerprint | Terminal retry cannot duplicate work; changed intent cannot reuse identity |
| Partial group evidence | Unresolved; no partial group presented as successfully finalized |
| Independent scopes | A suspended scope does not execute new work; an independent scope remains usable |
| Repeated reopening | Reconciliation remains stable across subsequent launches |

Assertions use independently specified expected values and history observations.
In-process save failures and actual process termination are separate evidence.
The results report identifies the exact termination technique and scenarios.

## Evidence boundaries

This probe does not implement native menus or focus (#48), package migration and
copying (#49), or branching/pruning and scale (#50). It does not validate the
100,000-group workload, multi-GiB payloads, production performance ceilings,
macOS 14, Intel, power-loss behavior or every possible filesystem failure.
A passing crash fixture on this host establishes only the recorded process-
interruption behavior using the operating system's storage APIs.

The implementation workflow uses the globally installed `workflow`, `implement`,
`tdd`, `prototype` and `code-review` skills. The accepted #47 requirement for
native persistence, automated assertions and failure handling takes precedence
over the prototype skill's generic HTML-only and no-test suggestions. See
[skill attribution](../../../docs/ai-skills.md).

Maintainer review remains required before closing #47. Compile/test success alone
does not accept the design or implement durable history in Folio.
