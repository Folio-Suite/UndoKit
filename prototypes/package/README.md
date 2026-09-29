<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Disposable package and compatibility proof (#49)

Run `ruby UndoKit/prototypes/package/run.rb` from the repository root. The Ruby wrapper runs the standalone Swift 6 package's tests with strict concurrency and warnings as errors. It records the source HEAD, source SHA-256 values, test log, resource peaks and limits in `.build/package-last-run.{json,log}`. A passing run removes its temporary package fixtures; a failing run retains them and prints their location. The wrapper refuses to start below 20 GiB free and enforces 2 GiB combined child RSS, 12 GiB owned disk and a maximum 600-second timeout (180 seconds by default). Environment overrides can lower these caps or extend the timeout only within 600 seconds.

The fixture is a small host, not a production UndoKit API. It keeps host text and current resource references in `contents.json`, immutable resource bytes under SHA-256 names in `Resources/`, and history records with their resource references in a separate WAL-backed Core Data SQLite store. `manifest.json` registers the working identity, schema, payload codec, generation and recording state. Programmatic v1/v2 models are intentional disposable compatibility fixtures; Folio production models remain Xcode-authored. All fixture calls are main-actor serialized.

`capture` makes a coordinated host copy: it writes content and resources to staging, asks Core Data to snapshot the active SQLite store with its journal, validates the staged package, and publishes the package. The host declares whether it is an independent copy; independent copies receive a new working identity while inherited history and generation remain. `move` retains identity and reattaches the original store after a failed move. `restore` records displaced text and its resource reference alongside the newly accepted host state. Migration and omission prepare and validate staging packages before replacing the working package, with the previous package retained until the new one opens. Omission removes obsolete resource files from staging after accounting for every scope's current resource. Failure hooks stop both before and during promotion to exercise rollback.

The tests observe the probe's package-facing methods and literal expected host states. They include two independent scopes in an app-local placement example. They do not inspect Core Data rows or SQLite internals. The only direct file checks verify WAL presence, the preservation of host files on failed maintenance, and that unsupported inputs are not rewritten.

## Evidence boundary

The probe demonstrates Core Data snapshot and lightweight schema migration behavior on this host. It does not implement UndoKit's accepted transaction protocol, cross-process ownership, package file coordination, a general resource dependency graph, structural history branches, or crash/power-loss recovery. The unresolved-outcome fixture is an admission fence; #47 supplies fuller delivery/finalization evidence. A displaced text/resource record is evidence of retention, not the branch model assigned to #50. The unavailable-store case is an injected access failure, not a filesystem permission or removable-volume test. Faults during original-package removal or a disk failure remain outside this deterministic rollback proof. Source SQLite and WAL bytes may change during Core Data's supported snapshot operation as it checkpoints the journal; tests require the source to reopen with its semantic history and host files intact.

Maintainer review is still required before issue #49 can be considered accepted or closed. This proof does not change Folio's production packages.
