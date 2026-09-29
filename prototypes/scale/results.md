<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# #50 persisted branching and retention proof results

The four mandatory workload runs completed on an Apple M3 Pro (Mac15,6,
18 GiB RAM), macOS 27.0, arm64, Apple Swift 6.4, using a release build.
The measured Swift source is commit 631bd231a5135d8a3de3345f52f5d6eec7a0672d:
HistoryStore.swift SHA-256 7288cee345fb34bf9016ff464c7755cc58a4b69d0ea6b3e9f0d44cffa8a328b1
and ScaleChild/main.swift SHA-256
3e936b7c28d1a4302fead14b7085a81405ccb29438d2c4085bf31fea1a566cab.
Ordinary and large used runner SHA-256
1a783bdcac59b48143a0a61c536f246c5d0c635c2abb1f771cd0be7f66169484.
KitchenMemory style and payload used runner SHA-256
723c6050dc65f70e1457d8c6f4da62374a58d578e981f0c17b99833891b2d05c
after separating JSON stdout from Core Data stderr and requiring complete
phase events. The Swift binary was unchanged. The reports contain all source
hashes, exact limits and every reopen result.

| Workload | Three fixture creation times | Encoded bytes per fixture | Full database plus sidecars at fixture completion | Highest sampled descendant RSS |
| --- | ---: | ---: | ---: | ---: |
| Ordinary, 10,000 groups | 2.74, 2.76, 2.64 s | 20,749,464 | 27.81–33.24 MiB | 101.8 MiB |
| Large, 100,000 groups | 70.50, 70.84, 70.79 s | 29,826,289 | 54.52–57.45 MiB | 1,030.0 MiB |
| KitchenMemory style, 10,000 submissions | 2.21, 2.21, 2.22 s | 2,587,155 | 3.71–4.12 MiB | 122.7 MiB |
| Payload, 100 groups | 4.27, 4.39, 4.44 s | 838,860,800 | 809.99 MiB | 792.2 MiB |

Fixture creation saves groups in batches of 100; it is reported separately
from the 1,000 individually durable small-operation groups appended to a
separate scope in each run, beyond the stated base fixture counts. These
small-edit times include a Core Data save in an empty queue with a lightweight
local fixture. They do not decompose #47's preparation, host acceptance and
finalization, or measure an end-to-end host callback.

| Workload | Per-run small-edit p50 (ms) | Per-run p95 (ms) | Per-run p99 (ms) | Per-run maximum (ms) |
| --- | --- | --- | --- | --- |
| Ordinary | 0.225, 0.229, 0.228 | 0.292, 0.297, 0.470 | 1.337, 1.122, 3.098 | 5.534, 4.966, 6.690 |
| Large | 0.224, 0.236, 0.236 | 0.284, 0.305, 0.277 | 0.934, 0.744, 0.601 | 13.154, 7.897, 8.196 |
| KitchenMemory style | 0.213, 0.213, 0.219 | 0.254, 0.255, 0.276 | 0.830, 0.745, 0.920 | 3.175, 3.345, 3.845 |
| Payload | 0.231, 0.263, 0.239 | 0.292, 0.551, 0.321 | 1.009, 1.260, 0.921 | 9.806, 5.878, 8.843 |

Each workload had ten fresh-process reopens per seed, 30 samples total.
Availability includes opening the Core Data store, reading the fixture's
target manifest and querying the current scope head. Page timing returns
100 lightweight Node records, or fewer when retained history has fewer
records. First material timing includes creating a Recovery Plan and reading
the first bounded page of actual Command/effect bytes. These are fresh
processes, not cold filesystem-cache measurements.

| Workload | Availability p95 / max (ms) | History page p95 / max (ms) | First material p95 / max (ms) | First-page bytes read |
| --- | ---: | ---: | ---: | ---: |
| Ordinary | 15.98 / 17.46 | 7.04 / 7.56 | 28.41 / 30.48 | 102,729 |
| Large | 10.93 / 11.24 | 42.42 / 43.86 | 116.09 / 118.64 | 29,775 |
| KitchenMemory style | 17.19 / 18.12 | 0.93 / 1.02 | 7.19 / 7.20 | 25,872 |
| Payload | 14.38 / 16.87 | 0.86 / 0.94 | 17.40 / 18.27 | 16,777,216 |

The page, first-material and clean-reopen measurements met the plan's
initial timing targets on this machine. The timing targets remain
investigation prompts, not production pass/fail guarantees. The complete
individual results are in evidence/ordinary.json, evidence/large.json,
evidence/kitchen.json and evidence/payload.json.

## Behavioral and retention observations

- The ordinary fixture retained 10,000 groups with occasional real 1 MiB
  combined encoded Command and effect bytes, two-Action groups and shared resource references.
  Its final state matched the independent expected-state dictionary.
- The large fixture retained 100,000 base groups across 100 branches and
  100 tip Checkpoints and one near-beginning proof Checkpoint (101 total).
  Near-beginning reconstruction visited 101 records
  and read 33,932 bytes; the distant divergent state visited 1,501
  records and read 450,808 bytes. Both matched exact expected dictionaries.
  Restoring the near-beginning state appended a new Action group, Undo
  returned to the displaced end state, and Redo returned to the restoration.
  Full-history reopen timings were collected before consolidation.
- The large consolidation then removed 98,498 groups and retained 2,503
  protected groups. Its requested 2,000-group retention target was unmet
  in every repetition, as required by the overlapping Checkpoints, hold,
  active Recovery Plan and current history. Consolidation took 8.31–8.38 s.
  The retained near-beginning and divergent states still matched their
  expected dictionaries, selected-material recovery succeeded, and the
  shared resource remained required. The consolidated database plus
  sidecars occupied about 9 MiB.
- The KitchenMemory-style fixture used four independent scopes, 96 rolling
  Checkpoints and 24 turnover prunes per repetition. Each final prune
  retained 404 groups: 100 detailed groups plus a baseline in each scope.
  Each scope then completed 100 Undo operations, refused the next Undo,
  completed 100 Redo operations and returned to its exact expected state.
- The payload fixture wrote 100 retained groups with 8 MiB of encoded
  Command data each. Its full database plus sidecars occupied 849,334,272
  bytes per repetition. The first Recovery Plan page read 16 MiB of actual
  bytes under the configured 16 MiB page cap.

The absolute sampled RSS remained below the runner's 2 GiB safeguard.
The plan's additional-memory targets of 256 MiB or 512 MiB above an
initialized fixture host were not measured; the large fixture's roughly
1 GiB absolute peak warrants separate allocation analysis. Peak owned
temporary/build footprint was about 196 MiB for the large fixture and
1.00 GB for payload; these runner totals include build files. The reports
also include each fixture's database-plus-sidecars footprint. Host-owned
resource bytes were not part of these fixtures.

## Small checks, runner faults and remaining gaps

The public small suite covers restoration and displaced work; repeated
Redo; selected recovery including an absent key; independent state and
detailed-history holds; overlap across a Checkpoint; explicit gaps;
protected Recovery Plans and expiry on reopen; ancestor-only shared
resources; lowered capacity and payload limits; and pruning complete
groups. After the four measured workloads, a first-group empty-baseline
Undo/Redo boundary and strict primary-store stat handling were added.
The resulting source passed 13 public-interface tests and a release smoke
run. The added hard-cap test verifies that refused acceptance leaves active
state and detailed-history holds, their held resource, and exact state intact
through reopen and pruning. The four workload measurements above remain tied to commit 631bd231;
the later boundary edits were not rerun at mandatory scale.

A deliberately lowered 1 MiB memory guard stopped a smoke child and kept
diagnostics. An injected monitor failure before the first process sample
also killed and reaped its child (signal 9; no remaining PID) and retained
the diagnostic report. Weaker unapproved environment limits are rejected.
A first KitchenMemory-style attempt returned successful child exits but
its JSON metrics were overwritten by interleaved Core Data stderr; it is
not counted as evidence. The separated-log rerun above includes all
required events.

This proof does not establish #47 host-authoritative acceptance and
interruption recovery, #48 native responsiveness or menu routing, or #49
store/package lifecycle. It does not demonstrate a permanently ineligible
group with host-declared independence, process termination during pruning,
serialized host-resource cleanup after pruning, post-consolidation return
to every displaced branch, full host reconstruction duration, queue
waiting, main-thread bridge latency, or incremental memory above the
initialized host. The exploratory 1–4 GiB streamed payload range was not
run. These remain unproved; neither successful compilation nor this
disposable representation promotes them to production guarantees.
