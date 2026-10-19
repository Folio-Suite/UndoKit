<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# History compatibility and safe opening

The authoritative compatibility policy is the [issue #6 resolution](https://github.com/Folio-Suite/UndoKit/issues/6#issuecomment-6104176471).
The [issue #8 resolution](https://github.com/Folio-Suite/UndoKit/issues/8#issuecomment-6104499789)
defines qualification evidence. This implementation supplies opening safeguards
and a reproducible development recipe. It does not seal or qualify a release.

## Opening supported stores

`HistoryStore.open` requires an explicit mode and the host's stable working identity.

| Mode/access | Behavior |
| --- | --- |
| `.create`, `.readWrite` | Creates a new registered store; refuses an existing file. |
| `.existing`, `.readWrite` | Validates the model and durable identity on an isolated copy before loading the original writable store. Owns the exclusive writer lock. |
| `.existing`, `.readOnly` | Validates compatibility and identity, then inspects a committed snapshot captured at opening. Never changes original database, journals, shared-memory sidecar, or owner file. Reopen to see later commits. |
| `.independentCopy(sourceWorkingIdentity:)`, `.readWrite` | Validates source identity and scope bindings before adopting a coherent copy for different host data. Receives a new physical store identity. The host must pair it with corresponding host state/resources. |
| `.independentCopy`, `.readOnly` | Refuses adoption because adoption changes durable identity. |

Missing existing history reports `missingHistory`; it never creates a replacement
or parent directory. Invalid SQLite content reports `corruptHistory`. Unsupported
models, including incompatible newer models, report `compatibility`. A wrong
working identity reports `identityConflict`. Unavailable files report
`unavailableStore`. A read-only flag is not evidence of format compatibility.

An inspection capture includes the database and any WAL or rollback journal;
committed pages can reside in the WAL. It excludes original shared-memory lock
state. Local writers cannot save during the synchronous MainActor capture.
Writable preflight holds the owner lock. Read-only opening can inspect a local
writer's committed state without taking its exclusive lock. The host must quiesce
cross-process writers and coordinate external moves/replacement during capture.
Artifact identity, byte count, modification time and change time are checked
across capture; detected concurrent changes refuse with `busy` so the host can
retry. This guard does not replace the host's file-coordination obligation.

Inspection files live in a private temporary directory and are removed on failed
opening, explicit close, or session disposal. Opening requires temporary space
for the database and journals; lack of space refuses opening and preserves source
history. This is a bounded safety tradeoff, not a claim of zero-copy opening or
performance qualification at large workloads. Writable access begins only after
model/identity validation. Hosts must explicitly close sessions.

## Migration and continuity promises

No model change or structural migration is introduced here. `HistoryV1` is
unchanged, and both Core Data automatic migration and inferred mapping remain
disabled. There is no supported migration that an opening policy could authorize
in this implementation, so no speculative migration option is exposed.
An incompatible model is safely refused. This does not promise an upgrade from
tagged `0.1.0`, experimental stores, or unpublished schemas.

The published `0.2.0` beta establishes the supported persisted-history baseline.
Patches preserve public source
compatibility and documented behavior; minor `0.x` releases may break source APIs
with explicit migration notes. Supported histories remain usable directly or
through supported structural migration, subject to host codecs and resources.

From `1.0.0`, breaking public APIs or persisted-history compatibility requires a
major release. Within a major release, supported old stores and callers continue
to work. Minor schema additions must be additive and non-critical: absence must
leave existing semantics, acceptance, and recovery intact. Older readers are not
promised access to newer stores.

A major release must provide a supported forward migration or documented staged
upgrade route for supported stores, including the qualified-preview-to-`1.0.0`
transition. A future supported migration must require explicit host opening
permission, report migration required without that permission, preserve a
recoverable original, validate its replacement, and commit only after successful
preparation. The host may grant permission automatically under its policy; the
framework does not prescribe user ceremony. This future requirement is not an
implemented migration or a future-version compatibility pass.

There is no downgrade guarantee. Restoring an older application may require a
coherent pre-upgrade copy of both host state and history. A format mismatch never
authorizes clearing history or resetting a generation. Structural migration does
not rewrite opaque host payload meaning. Hosts retain required codecs, resources,
semantic validation, authoritative receipts, and recovery evidence. History-store
migration is not a distributed atomic transaction with host data.

## Reproducible development baseline

[The recipe](../UndoKitTests/Fixtures/preview-baseline.json),
[its resource](../UndoKitTests/Fixtures/preview-resource-v1.txt), and
[the public-behavior fixture generator](../UndoKitTests/HistoryOpeningCompatibilityTests.swift)
retain fixed working/scope/command/member/checkpoint/resource identities, literal
expected state and chronology, codec requirements, the unchanged model-source
checksum, and the recipe's introduction source revision. The fixture host stores
state and authoritative effect receipts in one atomic JSON replacement. Its
codec is version 1 of `preview.counter.set`, canonical UTF-8 signed decimal
integers; `counter-description` version `v1` requires the named resource file.

The deterministic workload applies a two-member group setting 4 then 11,
checkpoints 11, sets 7, undoes to 11, and redoes to 7. It captures history, host
state/receipts and the resource under the coordinated-copy admission fence.
Close/reopen verifies literal chronology, retained resource references, the
checkpoint, isolated reconstruction to 7 and final host state. Structural IDs
and timestamps generated by UndoKit and SQLite layout may differ between runs;
reproducibility means the same scenario and independently expected behavior,
not byte-identical generated SQLite databases.

Run the focused evidence:

```sh
scripts/test-package.sh --filter HistoryOpeningCompatibilityTests
```

Export a concrete matched pair to an **absent** destination:

```sh
UNDOKIT_BASELINE_OUTPUT=/tmp/undokit-preview-baseline \
  scripts/test-package.sh \
  --filter testPreviewBaselineRecipeRetainsPairedHistoryStateCodecsAndResources
```

The export contains `History.sqlite`, `host-state.json`, `recipe.json` and the
resource. If sidecars exist after Core Data closes, retain them too; do not discard
journals by copying only the database. The introduction revision in the recipe
is provenance, not the final candidate identity.

At candidate qualification, retain the concrete matched pair generated by the
exact candidate alongside a seal recording source commit/clean status, artifact
checksums, compiled model identity, codec/resource requirements, OS, architecture,
toolchain, setup, command, actual test result and limitations. Hash all paired
files and the recipe. Preserve the sealed pair for later readers or supported
migration tests; regenerating it with a future version does not establish old
store continuity. Final sealing and hardware/platform qualification remain later
gates. The current fixture cannot prove compatibility with any future release.
