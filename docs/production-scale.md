<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Production scale protocol

This harness implements [#20](https://github.com/Folio-Suite/UndoKit/issues/20)
under the authoritative [#8 resolution](https://github.com/Folio-Suite/UndoKit/issues/8#issuecomment-6104499789).
It is a deterministic independent Swift host using the production source package.
A completed Mac workload is Mac evidence. Simulator smoke and an iOS build do not
qualify physical hardware; that evidence belongs to [#27](https://github.com/Folio-Suite/UndoKit/issues/27).
No binary, Intel, floor-OS, cold-cache or abrupt-termination claim follows.

## Fixture and independent truth

The mandatory size is 10,000 original Command Undo Groups. The first 100 form a
trunk, followed by 100 groups on continuation A. Undo reverses A to the trunk;
9,800 new groups form continuation B and displace A. Every tenth original group
has two Actions; others have one. Each original group contains 1,008 encoded
payload bytes across Command input and both accepted effects, except every 997th
which contains 1,048,560 bytes. Exact per-group sizes and member distributions are
retained. These sizes exclude fingerprints, structural metadata, SQLite overhead
and the 4 KiB shared host-owned resource. All accepted payload bytes, including
100 compensation groups and two restoration Commands, are reported separately.
The fixture records 10,102 accepted groups in total before maintenance.
This is the declared production profile, not the entire historical Folio or
KitchenMemory profile matrix.

Seeds 11, 12 and 13 determine stable Command/member/scope/store IDs and host values.
The host's state after original group `i` is `seed * 100000 + 2*i`; two-member groups
first set the immediately preceding odd value. The expected ledger is calculated
from fixture topology before interpreting any framework-returned material. For
seed 11 the earliest state is 1,100,002, continuation A ends at 1,100,400 and B ends
at 1,120,000. The durable host must finish with 10,102 accepted deliveries and
11,112 applied members. Bounded command tests additionally use independently
worked 100-group literal states and a deliberately corrupted host resource.

Recovery reads reconstruct the first group from B (10,099 visited transitions)
and the distant A tip from B (9,900 transitions). Reading must preserve current
content. Restoration submits a new host Command; reconstructing and submitting B
again verifies the displaced state can be recovered and adopted. Reports include
visited records, bytes consumed, first useful page and completion latency.

A detail hold protects the first group, another protects A's tip, and a state hold
protects the shared-ancestor checkpoint. A current-B checkpoint is the consolidation
boundary. Reopening with a 100-group ordinary allowance permits bounded 64-record
maintenance passes; at least one eligible group must be removed. The expected
protected IDs, whole-group member counts, checkpoint bytes, holds, shared resource
reference and original first-Command retry identity must survive. After consolidation,
the held ancestor is reconstructed directly from its checkpoint baseline. The
same independent checks run on every fresh-process readback. The 100-group smoke
uses a ten-group ordinary allowance to make retention observable.

The host appends one compact JSON record containing authoritative receipt and
complete host state, then synchronizes it before returning acceptance. Reopen
parses complete records and refuses malformed data. Host.json is a close-time
diagnostic snapshot, not a second acceptance authority. This deterministic host
is not a benchmark of a real host database or a host crash-recovery certification.

## Declared guards and measurement ownership

| Guard | Mac | Physical iOS default |
| --- | --- | --- |
| Runtime per fixture, including construction | 600 seconds including its ten fresh-process samples | 900 seconds; fresh readbacks separately bounded at 900 seconds each |
| Peak resident memory | 2 GiB combined runner and all descendant processes | 512 MiB complete app process, including host/engine/UI |
| Full allocated owned footprint | 12 GiB evidence plus entire reused Package cache | 2 GiB all fixture evidence plus installed app/runtime/resources |
| Remaining free storage | 20 GiB; preflight adds estimated 1 GiB fixture space | 4 GiB; inspect device headroom before run |
| Ordinary main-actor heartbeat gap | 1 second | 1 second |
| Heavy concurrency | One scale command | One foreground scale host |

The iOS defaults are predeclared bounded experiment choices, not advertised
production ceilings or proven jetsam-safe budgets. Record actual device family,
RAM, storage, OS and any maintainer-authorized change before a physical run. The
in-app monitor checks memory/disk/free space at 500 ms intervals and cancellation
at bounded work boundaries. The Mac outer watchdog additionally stops blocked
children and guards builds. During physical work, use Xcode/device monitoring as
an independent watchdog: stop and record a failure if the app stops reporting
progress or exceeds its predeclared time. A stalled main actor cannot execute its
own cooperative monitor. A stopped, skipped, cancelled or over-budget case fails;
a partial report or unrun checklist cannot pass acceptance.

Build databases are stable under `~/Library/Developer/Xcode/DerivedData/UndoKit`:
`Package` for Mac; `Scale/DeviceBuild` for iOS, with stable generated project
`Scale/DeviceProject`. `scripts/build-support.rb` defines the root and respects
`UNDOKIT_DERIVED_DATA`. Locks serialize mutable databases. Per-run directories
contain evidence and fixture stores, never new build databases. Mac reports count
all allocated files in evidence (host receipts/resources, History.sqlite/WAL/SHM,
logs, reports, staging/atomic-write files) plus the whole reused Package cache.
Initial, peak and final components distinguish persistent shared cache from
fixture work. Mac build RSS/disk/time are separately reported and still guarded.
Swift reports distinguish history files from host-owned resources/receipts and
retain full-process peak RSS. Device reports count all repetitions and the
installed app. Retain the exact external device build manifest separately.

Small original submissions and occasional large submissions have separate
p50/p95/p99/max and the ten slowest operation indexes. Undo, metadata pages,
construction, maintenance, host delivery and reconstruction are separate phases.
Submission latency is end to end; framework preparation/finalization and queue
waiting are not separately instrumented by this public host seam. Ten fresh
reopens retain every availability/total measurement and PID, plus a summary
latency distribution. Responsiveness heartbeat is automated scheduling evidence;
physical scrolling/navigation/cancellation and ordinary interaction observations
must be recorded separately. Historical timing/efficiency targets and 100,000/
800 MiB workloads are advisory; correctness, controlled limit refusal and ordinary
responsiveness are mandatory.

## Commands

From a clean, committed source checkout, run the default Mac production command:

```sh
ruby scripts/check-undokit-scale.rb
```

The command declares budgets before building, retains source commit/dirty paths
and actual source hashes, hardware/OS/toolchain/configuration, exact binary/runtime/
compiled-model/privacy hashes, phases, outliers and full owned-footprint evidence.
A non-clean source inventory is explicit and cannot serve as exact candidate
qualification. `mac_workload_completed` requires three 10,000-group fixtures and
ten fresh processes per fixture. Other smaller runs say `smoke_completed`;
100,000-group runs say `advisory_completed`. Timing targets do not change status.
The default evidence folder is printed and retained under `Scale`; choose a new
`--output PATH` to select a location. Existing reports are never overwritten.

Bounded verification and staging:

```sh
ruby scripts/test-scale-runner.rb
ruby scripts/check-undokit-scale.rb --groups 1000 --repetitions 1 --reopens 2
UNDOKIT_SCALE_SMOKE=1 scripts/test-package.sh --filter HistoryScaleTests
ruby scripts/check-undokit-scale.rb --groups 100 --repetitions 1 --reopens 1 --max-rss-bytes 1
```

The final command deliberately fails without a large allocation and retains a
budget diagnostic. Overrides can only lower Mac guards. The command tests also
verify graceful nonzero refusal after a host resource is corrupted; it must not
write a passing readback report. These checks are not full production evidence.

Build the iOS app with stable caches:

```sh
ruby scripts/build-scale-device.rb --sdk iphonesimulator
ruby scripts/build-scale-device.rb --sdk iphoneos --team YOUR_TEAM_ID
```

The second command uses automatic signing/provisioning for the supplied development
team. Open the printed project in Xcode and install on the selected physical device.
The signed app embeds the prebuild source/toolchain/configuration manifest; the
external `Scale/DeviceProject/BuildManifest.json` records exact signed artifacts.
Keep that manifest with the exported app/container and physical observations.
The build command leaves signed products intact after hashing.

Create each seed 11–13 once using the picker or launch arguments:

```text
--scale-operation create --scale-groups 10000 --scale-seed 11
```

After completion and graceful store closure, stop the process through Xcode. Launch
again with the following arguments for samples 1–10, stopping the completed process
between samples, and repeat for each seed:

```text
--scale-operation reopen --scale-seed 11 --scale-sample 1
```

Stopping an already completed/closed process establishes fresh-process measurement;
it is not a crash test. The in-app current-process readback writes sample 0, which
is excluded from acceptance. Existing fixture/sample evidence cannot be overwritten.
Simulator smoke uses `--scale-groups 100` and the exact same host, but reports
`iOS Simulator (smoke only)` and cannot pass physical evidence review.

Download the data container through Xcode. Its
`Library/Application Support/UndoKitScaleEvidence` contains each seed's budgets,
manifest, workload/fresh-process reports, durable host receipts and history store.
Record device model/RAM/OS, navigation/scrolling/Cancel observations, run start/end,
resource monitoring, failures and limits in a separate observations file. Inventory
physical evidence with:

```sh
ruby scripts/check-scale-device-evidence.rb --evidence PATH_TO_UndoKitScaleEvidence \
  --build-manifest EXACT_BUILD_MANIFEST.json --observations PHYSICAL_OBSERVATIONS.md
```

The inventory refuses simulator reports, missing fixtures/samples, repeat PIDs,
failed artifacts, changed expected state and declared budget overruns. Its
`physical_evidence_complete_for_review` result still requires maintainer review;
observations are human evidence, not inferred from a nonempty file. Actual physical
qualification remains deferred to #27 until that work is performed.
