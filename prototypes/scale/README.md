<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Disposable branching and retention proof (#50)

This package tests a persisted Core Data history graph and deterministic scale
fixtures. It is not the UndoKit production API.

    swift test --package-path UndoKit/prototypes/scale
    ruby UndoKit/prototypes/scale/run.rb ordinary
    ruby UndoKit/prototypes/scale/run.rb large
    ruby UndoKit/prototypes/scale/run.rb kitchen
    ruby UndoKit/prototypes/scale/run.rb payload

Run one large case at a time. The Ruby runner obtains an exclusive lock, builds
the release executable, makes three independent fixtures with seeds 17, 29 and
43, adds 1,000 individually saved small-operation groups in a separate
scope beyond each base fixture count, and launches ten fresh processes to reopen each fixture. Its watchdog stops and reaps a case
that exceeds 600 seconds per repetition, 2 GiB descendant RSS, 12 GiB owned
temporary/build space, or the 20 GiB remaining disk floor. Environment settings
may tighten those bounds. KEEP_FIXTURES=1 retains successful fixture stores;
failed fixtures, logs and reports are retained automatically. The runner
requires fixture, operation, reopen and consolidation metric events before it
reports success. It records source SHA-256 values, toolchain and host details,
each reopen sample, runner limits, process exits and sampled peaks. Full reports
from the mandatory runs are in evidence/.

The dynamic Core Data model keeps Scopes, Nodes, Effects, Checkpoints, Holds,
References, Plans and Redo entries as separate records. Each Node is one complete
Undo Group with explicitly ordered Effects and a parent in its History Branch.
Command and accepted-effect bytes are stored independently within each Effect.
Checkpoints hold encoded host-state snapshots; explicit gaps mark consolidated
detail. A fixture-only fork operation constructs divergent branches without
presenting branch checkout as an interactive API. Interactive restoration and
selected-material recovery append new groups with origin identities. A retained
Redo stack supports repeated whole-group Undo/Redo. Configured Undo depth
protects its detailed window across Checkpoints, with a recoverable floor state.
State and detailed-history holds remain independent. Recovery Plans expire on
reopen, and pruning removes only unprotected groups in atomic batches.
Checkpoint references conservatively include ancestor references because this
probe has no host semantic dependency oracle; this can over-retain resources.

Fixture generation batches saves every 100 groups, so its creation time is
separate from interactive commit latency. The measured small-operation phase
uses one durable Core Data save per edit. The independent expected-state
dictionary checks resulting states for the ordinary, large, bounded and payload
fixtures. The large fixture reconstructs distant states before consolidation,
measures full-history reopens, then runs protected consolidation in a separate
process and compares exact states again. The history page bound is 256 entries
and the Recovery Plan page byte bound in this experiment is 16 MiB. A first
Recovery Plan page reads actual opaque bytes within that bound. The payload
case writes 8 MiB per group, using a deterministic 64 KiB pseudorandom chunk
repeated to fill each real in-memory encoded Command. These bytes are stored in
SQLite; they do not stand in for host-owned attachments.

## Exact generated workloads

- Ordinary: 10,000 groups in one scope, 1,024 encoded bytes in each ordinary
  group and 1 MiB in every thousandth group. Every twentieth group has two
  Actions; every 200th cites a shared retained resource.
- Large: 1,000 trunk groups followed by 100 branches of 990 groups from the
  same trunk endpoint, for 100,000 base groups. Every twentieth branch group
  has two Actions; every hundredth uses 4,096 encoded bytes and cites a shared
  resource. Each branch tip has a Checkpoint, and the near-beginning proof adds
one more (101 total). A near-beginning state, an early
  divergent branch state and the displaced end state are checked against
  independent expected dictionaries. Restoration adds one group after the
  100,000-group fixture. Consolidation runs only after full-history reopens.
- KitchenMemory style: 10,000 successive submissions across four scopes.
  Rolling Checkpoints and pruning leave 100 detailed groups plus a baseline
  in each scope. Every scope performs 100 Undo operations, refuses the next,
  then performs 100 Redo operations and checks exact state.
- Large payload: 100 groups with 8 MiB of real encoded Command bytes in each;
  the accepted-effect value is a small marker. The retained encoded total is
  838,860,800 bytes before database overhead.

## Evidence boundaries

This probe represents accepted outcomes and inverse traversal structurally.
It does not perform #47's separate host-store acceptance protocol, durable
preparation/finalization stages, interruption reconciliation or compensation
Actions. The fixture-host work is deterministic and local; queue waiting,
native main-thread bridge time, host callbacks and user-perceived responsiveness
are not measured here. Reopen measurements are fresh processes, not cold
filesystem-cache measurements. Recovery builds an in-memory metadata index of
the fixture's Nodes; opaque payload material is fetched in bounded pages.
The memory target's increment above an initialized host is not established by
the runner's absolute sampled RSS. The 1–4 GiB exploratory payload range
requires a streamed adapter and was not attempted.
