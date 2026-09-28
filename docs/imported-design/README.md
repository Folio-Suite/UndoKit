<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Preserved UndoKit design and repository history

**Remote status:** the maintainer confirmed deletion of `ctwelve/UndoKit` on 2026-09-27. Folio owns the preserved design work and successor tickets. The original source was a scaffold; its small Git archive is retained only as optional historical provenance.

The original `ctwelve/UndoKit` repository is retired by explicit maintainer direction after preservation. Folio now owns active planning and future development. UndoKit will be a Swift framework, serving Folio first and KitchenMemory second, with generic capabilities and host-owned policy. External distribution and independently usable Objective-C interfaces are deferred beyond Folio Suite 1.0; original requirements remain historical evidence rather than current gates.

## Verified preservation

- [Final tracker snapshot](retirement-snapshot-2026-09-27.json): all 18 issues, four comments, 128 events, labels/states/timestamps, and original parent/blocker relationships; repository metadata and empty release/PR/tag/discussion inventories are included.
- [Original import snapshot](issues-2026-09-27.json): unchanged provenance from the initial source import.
- [Complete Git history bundle](undokit-history.bundle): all ten commits and the sole main branch at `5ca57fd54f91ad754ca3d0d8398f67745a7b5be7`. `git bundle verify`, an independent clone and `git fsck --full` passed. The restored vocabulary, license and all three research documents match the imported copies byte for byte.
- There were no releases, tags, pull requests, discussions or issue attachment URLs to migrate. Wiki support was enabled, but no wiki Git repository existed. The separate local checkout was clean and remains available.
- Original MIT attribution is retained. The bundle also retains original source, configuration, local workflow material and historical Git metadata without adding a nested repository.

## Original issue disposition

| Original issue | Preserved or continued in Folio |
| --- | --- |
| #1 | [#51](https://github.com/Folio-Suite/Folio/issues/51) Accept UndoKit design for Folio implementation |
| #2 | Resolved research/ownership decision retained in the tracker snapshot and imported research/vocabulary; no duplicate work ticket. |
| #3 | Resolved research/ownership decision retained in the tracker snapshot and imported research/vocabulary; no duplicate work ticket. |
| #4 | Resolved research/ownership decision retained in the tracker snapshot and imported research/vocabulary; no duplicate work ticket. |
| #5 | Resolved research/ownership decision retained in the tracker snapshot and imported research/vocabulary; no duplicate work ticket. |
| #6 | [#41](https://github.com/Folio-Suite/Folio/issues/41) Define UndoKit durable acceptance and interruption recovery |
| #7 | [#42](https://github.com/Folio-Suite/Folio/issues/42) Define UndoKit branches, checkpoints, and bounded retention |
| #8 | [#43](https://github.com/Folio-Suite/Folio/issues/43) Define typed Swift UndoKit payload and host interfaces |
| #9 | [#44](https://github.com/Folio-Suite/Folio/issues/44) Define native UndoKit routing and restored availability |
| #10 | [#45](https://github.com/Folio-Suite/Folio/issues/45) Define UndoKit store lifecycle and safe capacity |
| #11 | External XCFramework distribution deferred beyond Folio 1.0; full original question retained in the snapshot. |
| #12 | [#46](https://github.com/Folio-Suite/Folio/issues/46) Set UndoKit acceptance scenarios and measured budgets |
| #13 | [#51](https://github.com/Folio-Suite/Folio/issues/51) Accept UndoKit design for Folio implementation |
| #14 | [#47](https://github.com/Folio-Suite/Folio/issues/47) Prove UndoKit interruption recovery and durable invalidation |
| #15 | [#48](https://github.com/Folio-Suite/Folio/issues/48) Prove UndoKit native restoration and focus behavior |
| #16 | [#49](https://github.com/Folio-Suite/Folio/issues/49) Prove UndoKit package and compatibility failure preservation |
| #17 | [#43](https://github.com/Folio-Suite/Folio/issues/43) retains the relevant typed Swift independence/payload proof; external Objective-C/XCFramework proof is deferred. |
| #18 | [#50](https://github.com/Folio-Suite/Folio/issues/50) Prove UndoKit branching and retention at the agreed scale |

Original dependency identities are preserved in the snapshot. The successor graph removes external distribution as a prerequisite and uses native Folio blockers. Recovery, branch semantics, payloads, native routing, store lifecycle, measured proof budgets and human review remain outstanding.

## Accepted boundaries

Hosts retain semantics, no-op filtering, validation, compensation, accepted outcomes, recovery evidence, store location and policy. UndoKit owns shared history capabilities, its separate Core Data history store, native adapters and storage safeguards. Recording does not establish domain acceptance. Folio document history and KitchenMemory's bounded policy remain distinct; no framework-wide `Revision` replaces host terminology.

## Recover the original repository

From a local checkout of this inventory, run `git clone undokit-history.bundle <destination>` to restore the complete original Git repository. The JSON snapshots preserve tracker data separately because issues and comments are not Git objects. Historical original URLs will no longer resolve after deletion; use this inventory and the successor links above.
