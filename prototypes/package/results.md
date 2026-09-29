<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Package proof results

Initial checkout baseline: `00852f423740655fc596761e1321fa663e0320cd` on `codex/prototype-undokit-native-storage-scale`. The final runner observed HEAD `8fe3d41fecfe4f6a21ff22ce3eb9d832f2eadb71` after other coordinated work advanced the shared branch. The runner's local JSON artifact records exact package source hashes at execution time; the runner safety change passed coordinated Standards and Spec review and was committed in `f83a3b0c0142307681c84603748f9e379c48a53e`.

Run on 2026-09-29: Apple Swift 6.4, macOS Darwin 27.0.0, arm64. `ruby UndoKit/prototypes/package/run.rb` completed with eleven Swift Testing cases passing. The wrapper enforced a 180-second run limit, 2 GiB combined child RSS, 12 GiB owned disk and a 20 GiB free-space floor. The last completed run sampled 156,663,808 bytes peak child RSS, 77,926,400 bytes peak owned disk and 2.08 seconds elapsed. These are watchdog samples, not calibrated benchmarks. A separate injected monitor failure exited 124 after killing and reaping its child. [The execution ledger](evidence.md) preserves the exact source hashes, commands, exit statuses and metrics; the full final report and log remain under `.build/` locally.

| Case | Observed result |
| --- | --- |
| Live WAL copy and independent registration | Coherent content, two history records and both immutable resource versions reopened in the copy; new working identity, unchanged source, independent later edit. |
| Move, Save As and restoration | Move retained identity; Save As copy received a new one; restoration staged selected content/resource and displaced text/asset together. A failure between state and displaced record left the source package unchanged. |
| Recording Off, checkpoint, On and omission | Off-period edit omitted from detailed history, checkpoint retained its asset after a later asset change, On established a current baseline. Failed staged omission left host files and reopened history intact. Success advanced generation and preserved the current asset. |
| Legacy migration and interrupted preparation | Stopped staged v1→v2 upgrade preserved the v1 package and resource. Successful lightweight upgrade retained old asset bytes and accepted a subsequent v2 edit and asset. |
| Compatibility/opening failures | Newer schema, unknown payload codec, missing history, corrupt SQLite and injected unavailable history reported distinct errors. Deliberately history-free package opened empty. Unsupported inputs were not rewritten. |
| App-local two-scope store | Both scopes retained their own records and assets in one SQLite store and backup. Omission preserved both scopes' current assets; unresolved outcome refused portable capture. |
| Promotion rollback | Faults after moving the original aside and after attaching the new store restored the original package; reopening and later edits retained historical assets. This covered migration and omission. |
| Failed move | Injected and filesystem move failures reattached the original history store; a later save recorded a second action and reopened. |
| Failed history save | Injected failure after Core Data record insertion rolled back the pending object and restored host content. Reopen and later save showed no failed Action or asset mismatch. |
| Missing or corrupt retained asset | Opening and portable capture refused a missing or hash-mismatched older asset even though current content used a different asset; the damaged input was unchanged and no copy was published. |
| Failed rollback | Injected rollback blockage reported the retained original package path, disabled further writes on the affected probe, and allowed inspection of that original through a new probe. |

## #49 criteria and remaining gaps

| Criterion | Evidence or gap |
| --- | --- |
| Disposable package save/copy/move/Save As/restore with WAL and resources | Exercised by the package tests above; historical resource bytes are read through the probe. |
| Recording Off/checkpoint/On, omission and generation | Exercised, including different checkpoint/current assets, failed and successful omission, and a two-scope current-resource check. |
| Structural and payload compatibility; missing/corrupt/unavailable | v1→v2 lightweight migration, unknown schema/codec markers, missing/corrupt history, injected unavailable history and missing/corrupt retained assets exercised. |
| Source preservation across tested failures | Staged restoration, migration/omission promotion and history-save faults exercised. A forced rollback failure retains its original at the reported path and disables the affected probe. Actual disk failure during rollback remains untested. |
| Actual persistence write failure after preflight | The injected fault throws after insertion, before `context.save()`. It proves pending-object rollback on that path; a real Core Data write failure during save and a failure while rolling back host JSON remain unproved. |
| Competing writable owner | Not implemented or proved by this fixture. |
| Acceptance close/reopen interruption and process kill | This fixture tests ordinary reopen and deterministic faults. [#47](../recovery/results.md) tested process kills and transaction recovery in a separate host/history arrangement; it does not establish package close/reopen interruption. |
| Store-capacity admission refusal | Not implemented or proved. The runner's resource ceilings are safeguards, not store admission behavior; [#47's lowered-watchdog experiment](../recovery/evidence.md) also establishes only runner refusal. |

Core Data emitted an expected SQLite corruption diagnostic while opening the deliberately corrupted fixture. No production schema or package was touched. The exact limitations and untested behaviors are in [README.md](README.md#evidence-boundary).
