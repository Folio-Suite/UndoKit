<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Versioned DocC site

UndoKit's DocC catalog, guides, and examples live in `UndoKit/UndoKit.docc`.
Generated output is staged from a fixed source checkout and promoted through a
manual GitHub Pages workflow. A successful DocC build or local stage is not proof
that the Pages site is live.

## Prepare a candidate

Run the producer build from the selected checkout. It records the checkout's
full commit, whether the worktree was dirty, the exact Xcode/Swift toolchain, the
`xcodebuild docbuild` command, and a SHA-256 tree identity for the produced
`.doccarchive`.

```sh
ruby scripts/documentation/site.rb build \
  --source . \
  --derived-data /tmp/UndoKit-docs-derived \
  --producer-output /tmp/UndoKit-docs-producer.json
```

Stage the archive without replacing an existing candidate directory. Release
candidates require a clean source tree. A dirty source tree can only be staged
as development documentation and receives an explicit dirty-source label.

```sh
ruby scripts/documentation/site.rb stage \
  --archive /tmp/UndoKit-docs-derived/Build/Products/Debug/UndoKit.doccarchive \
  --producer /tmp/UndoKit-docs-producer.json \
  --output /tmp/undokit-docs-candidate \
  --version 0.2.0 \
  --channel release \
  --base-path /UndoKit/versions/0.2.0/
```

The candidate contains `manifest.json`, `producer.json`, the exact input
`archive/`, and generated `site/`. The manifest records the source identity,
channel, deployment prefix, toolchain and producer command, plus SHA-256 tree
hashes for the archive and final static bytes. The stage command verifies
navigation and local links against that version's deployed path, checks search
assets and direct-refresh targets, and adds a visible source/version label. It
also fixes the root DocC entrypoint's asset and `baseUrl` paths for the Pages
project prefix. The resulting site hash covers those final bytes.

The version 1 manifest has `schemaVersion`, `version`, `channel`, `sourceCommit`,
`sourceDirty`, `basePath`, `toolchain` (`xcode`, `swift`, `clang`), `archivePath`,
`archiveTreeSHA256`, `sitePath`, `siteTreeSHA256`, `producerPath`,
`producerCommand`, and `producerSHA256`. The producer record binds the archive
hash to the same source SHA, dirty-state flag, toolchain strings, and command.
Tree hashes cover sorted recursive entries: a file contributes
`F\0<relative path>\0<SHA-256 of file bytes>\0`, a directory contributes
`D\0<relative path>\0`, and a symbolic link contributes
`L\0<relative path>\0<link target>\0` to the outer SHA-256 stream. Promotion
checks the producer, archive, and generated-site checksums again.

Development candidates use `--channel development` and
`--base-path /UndoKit/development/<sourceCommit>/`. They are separate from the
release snapshot namespace.

## Review and promote

Verify or stage candidates locally before promotion. Promotion checks the
producer, archive, and generated-site checksums again. The release snapshot is
written under `versions/<version>/`; `latest/` is changed only by a separate
operation after a matching GitHub release and source tag are visible. Promotion
of an existing version requires `--correction` and the same source commit; the
previous successful snapshot is retained under `history/<version>/`, and the
correction appears in `corrections.json` and as a visible note on that version's
landing page.

```sh
ruby scripts/documentation/site.rb promote \
  --artifact /tmp/undokit-docs-candidate \
  --release-provenance /tmp/UndoKit-0.2.0-manifest.json \
  --destination /tmp/undokit-pages
```

The repository workflow is `workflow_dispatch` only and has two operations. `stage`
checks out the selected full source SHA on the pinned Xcode runner, runs the
producer command, validates the generated site, and uploads the candidate as the
`undokit-docs-candidate` Actions artifact for local inspection or use by the
preparer. The artifact expires after 90 days.

`promote` downloads a candidate by its Actions run ID, verifies the published
GitHub prerelease and tag commit, downloads the retained candidate manifest
asset named `UndoKit-<version>-manifest.json`, and checks its complete
`documentation` object against the staged artifact before combining it with prior snapshots from the
`documentation-snapshots` branch. It applies any visible correction, updates the
latest landing, commits the preserved Pages tree to that state branch, and
uploads the same tree to Pages. On first use, set `initialize_snapshots` only
after confirming there is no previous Pages site to preserve. The state branch
is updated before the Pages deployment; if deployment fails, the previously
hosted site remains the reference while the branch retains all snapshots for a
retry. GitHub Pages must be enabled for this repository before the workflow can
deploy. No release documentation or latest pointer should be deployed before
the coordinated release is approved. The retained manifest uses schema 1 with
`releaseVersion`, `sourceCommit`, and the full version 1 DocC manifest under
`documentation`; `verify-release`, `promote`, and `update-latest` compare the
candidate's source identity and full archive, producer, and final-site hashes.

A successful local transform, artifact validation, or workflow configuration
does not establish live hosting. After deployment, verify navigation, search,
symbol links, assets, and a direct refresh of a symbol/guides deep link under
`https://<owner>.github.io/UndoKit/versions/<version>/`; retain the actual result
and any limitations with release evidence.
