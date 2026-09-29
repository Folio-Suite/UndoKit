<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Package proof results

Initial checkout baseline: `00852f423740655fc596761e1321fa663e0320cd` on `codex/prototype-undokit-native-storage-scale`. The final runner observed HEAD `6e6387932cc8a669468d890e1ff1478037119c0b` after other coordinated work advanced the shared branch. The runner's local JSON artifact records exact package source hashes at execution time; this proof directory remains uncommitted for coordinated review.

Run on 2026-09-29: Apple Swift 6.4, macOS Darwin 27.0.0, arm64. `ruby UndoKit/prototypes/package/run.rb` completed with eight Swift Testing cases passing. The wrapper enforced a 180-second run limit, 2 GiB combined child RSS, 12 GiB owned disk and a 20 GiB free-space floor. The last completed run sampled 396,984,320 bytes peak child RSS, 77,348,864 bytes peak owned disk and 3.62 seconds elapsed. These are watchdog samples, not calibrated benchmarks. See `.build/package-last-run.json` and `.build/package-last-run.log` for the exact source hashes and log.

| Case | Observed result |
| --- | --- |
| Live WAL copy and independent registration | Coherent content, two history records and both immutable resource versions reopened in the copy; new working identity, unchanged source, independent later edit. |
| Move, Save As and restoration | Move retained identity; Save As copy received a new one; restoration returned the selected content/resource and retained displaced text and asset bytes. |
| Recording Off, checkpoint, On and omission | Off-period edit omitted from detailed history, checkpoint retained its asset after a later asset change, On established a current baseline. Failed staged omission left host files and reopened history intact. Success advanced generation and preserved the current asset. |
| Legacy migration and interrupted preparation | Stopped staged v1→v2 upgrade preserved the v1 package and resource. Successful lightweight upgrade retained old asset bytes and accepted a subsequent v2 edit and asset. |
| Compatibility/opening failures | Newer schema, unknown payload codec, missing history, corrupt SQLite and injected unavailable history reported distinct errors. Deliberately history-free package opened empty. Unsupported inputs were not rewritten. |
| App-local two-scope store | Both scopes retained their own records and assets in one SQLite store and backup. Omission preserved both scopes' current assets; unresolved outcome refused portable capture. |
| Promotion rollback | Faults after moving the original aside and after attaching the new store restored the original package; reopening and later edits retained historical assets. This covered migration and omission. |
| Failed move | Injected and filesystem move failures reattached the original history store; a later save recorded a second action and reopened. |

Core Data emitted an expected SQLite corruption diagnostic while opening the deliberately corrupted fixture. No production schema or package was touched. The exact limitations and untested behaviors are in [README.md](README.md#evidence-boundary).
