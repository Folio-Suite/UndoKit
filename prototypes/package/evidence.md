<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Package proof execution ledger

This records the successful local run on 2026-09-29. The full machine-generated report and test log were written to `.build/package-last-run.json` and `.build/package-last-run.log`; those build artifacts are ignored. The run used Apple Swift 6.4 on macOS Darwin 27.0.0 arm64.

Command from the repository root: `ruby UndoKit/prototypes/package/run.rb`. The wrapper launched `xcrun swift test --package-path <absolute package path> -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`. Swift Testing reported **11 tests passed in one suite**. The wrapper exited **0**, with no limit reason and no child signal. The deliberate corrupt-SQLite input produced a Core Data corruption diagnostic while its failure-classification test passed.

The runner observed repository HEAD `8fe3d41fecfe4f6a21ff22ce3eb9d832f2eadb71`. The package source was undergoing coordinated review at that HEAD; the hashes below pin the exact tested code and runner independently of later branch movement.

| Tested file, relative to `UndoKit/prototypes/package/` | SHA-256 |
| --- | --- |
| `Package.swift` | `0bc12a71610addc33b502c3dd444b09c0f1efcca393d8b3cfac73b9ce67dcc47` |
| `Sources/PackageProbe/PackageProbe.swift` | `ac041db27c014a438b4f5653856ed6f78520b35ebad311d4a549809f4220790d` |
| `Tests/PackageProbeTests/PackageProbeTests.swift` | `bd6ae6224298251c2c63904c066a358bb88bf9d908f2d8830dd2b222f1a26ff9` |
| `run.rb` | `e93e0a168237a92303a75448feb49a82d9525a51fb68464d31892f218aba7f08` |

| Runner observation | Value |
| --- | ---: |
| Runtime limit | 180 seconds |
| Combined child RSS limit | 2,147,483,648 bytes |
| Owned disk limit | 12,884,901,888 bytes |
| Free-space floor | 21,474,836,480 bytes |
| Sampled peak child RSS | 156,663,808 bytes |
| Sampled peak owned disk | 77,926,400 bytes |
| Elapsed wall time | 2.077414 seconds |
| Child exit status | 0 |

## Monitor-failure shutdown check

Before the normal run, `PACKAGE_PROBE_INJECT_MONITOR_FAILURE=1 ruby UndoKit/prototypes/package/run.rb` injected an exception before the first `ps` descendant sample. The runner exited **124** and retained its temporary fixture directory. Its report recorded `failure_phase: monitor`, `reason: runner failure during monitor: RuntimeError: injected monitor failure`, child PID `41187`, `child_signal: 9`, `child_reaped: true`, and an empty `termination_errors` list. A subsequent `ps -p 41187 -o pid=` returned no process. This check demonstrates process-group termination even when the monitor has no descendant list yet. The following normal run replaced `.build/package-last-run.json`; these diagnostics are preserved here.

The memory and disk peaks are watchdog samples, not calibrated performance results. The runner removed its temporary fixtures after success. [Results](results.md) records scenario outcomes and the remaining #49 acceptance gaps.
