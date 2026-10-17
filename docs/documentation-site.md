<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Versioned DocC site

UndoKit's DocC catalog, guides, and examples live in `UndoKit/UndoKit.docc`.
Generated output is staged from a fixed source checkout and promoted through a
manual GitHub Pages workflow. A successful DocC build or local stage is not proof
that the Pages site is live.

## Check the authored guides

The integration guides contain Swift snippets extracted directly into a generated
consumer by this check. Run both configurations after changing the examples:

```sh
ruby scripts/check-documentation-examples.rb --configuration Debug
ruby scripts/check-documentation-examples.rb --configuration Release
```

The Mac path compiles the AppKit/SwiftUI examples and executes the first-document
walkthrough, verifying persisted host state, receipts, Undo/Redo and reopen.
The iOS path compiles the UIKit/SwiftUI examples against the Simulator SDK; it does
not launch a simulator app or establish native-input acceptance. Use `--platform
macos` or `--platform ios-simulator` for a focused check. The generated package and
locked build caches live under the shared DerivedData root. Per-run summaries
retain source/diff and guide hashes, configuration, toolchain and actual checks.

DocC compilation separately checks symbol/article links and asset references.
For an editorial pass, add `OTHER_DOCC_FLAGS="--warnings-as-errors"` to the Xcode
`docbuild` invocation. Inspect the rendered landing page, platform guides and
diagrams at both narrow and normal widths. Keep generated Core Data declarations
separate from the supported integration story; do not edit generated code or the
installed Xcode templates merely to silence their diagnostics.

## Prepare a candidate

Run the producer build from the selected checkout. It records the checkout's
full commit, whether the worktree was dirty, the exact Xcode/Swift toolchain, the
`xcodebuild docbuild` command, and a SHA-256 tree identity for the produced
`.doccarchive`.

```sh
ruby scripts/documentation/site.rb build \
  --source . \
  --derived-data "$HOME/Library/Developer/Xcode/DerivedData/UndoKit/Documentation" \
  --producer-output /tmp/UndoKit-docs-producer.json
```

Stage the archive without replacing an existing candidate directory. Release
candidates require a clean source tree. A dirty source tree can only be staged
as development documentation and receives an explicit dirty-source label.

```sh
ruby scripts/documentation/site.rb stage \
  --archive "$HOME/Library/Developer/Xcode/DerivedData/UndoKit/Documentation/Build/Products/Debug/UndoKit.doccarchive" \
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
release snapshot namespace and always carry a development label, including for clean
source checkouts. The dirty-source label is additional provenance. Toolchain
identity is captured by the producer; callers cannot supply version strings.

## Review and promote

The retained release candidate manifest is the immutable asset
`UndoKit-<version>-manifest.json`. Schema 1 binds `releaseVersion`, `sourceCommit`,
and the complete original DocC artifact manifest under `documentation`. Initial
promotion requires that exact original artifact; a replacement self-authored
manifest is not release approval.

```sh
ruby scripts/documentation/site.rb verify-release \
  --artifact /tmp/undokit-docs-candidate \
  --release-provenance /tmp/UndoKit-0.2.0-manifest.json
ruby scripts/documentation/site.rb promote \
  --artifact /tmp/undokit-docs-candidate \
  --release-provenance /tmp/UndoKit-0.2.0-manifest.json \
  --destination /tmp/undokit-pages
ruby scripts/documentation/site.rb update-latest \
  --artifact /tmp/undokit-docs-candidate \
  --release-provenance /tmp/UndoKit-0.2.0-manifest.json \
  --destination /tmp/undokit-pages
```

`verify-release` checks the published GitHub prerelease and its tag against the
released API source. All commands verify producer/archive/site identities;
`promote` copies staged bytes unchanged into `versions/<version>/`, adding only
the artifact's identity manifest beside them. `update-latest` requires that full
promoted snapshot, refuses to move backward, and updates the root and `latest/`
entry points. An exact installed artifact is an idempotent promotion retry.
GitHub lookups explicitly target `Folio-Suite/UndoKit`, including when invoked
outside a checkout.

## Correct released guidance

A guidance correction has its own reviewed candidate. It preserves the original
release tag, API source commit, original release manifest, and binary assets.
The first supported correction scope is regular `.md` files beneath
`UndoKit/UndoKit.docc/`. The complete Git tree diff from the released source to
the documentation source must contain only those files. Code, project settings,
resources, scripts, symlinks, and submodules are refused. The released commit
must be an ancestor of the clean documentation checkout. Maintainer review must
also confirm the guidance does not advertise newer APIs or compatibility
promises; the file restriction does not establish semantic correctness.

Build at the new documentation source commit using the producer command above,
then stage against the original published release manifest and the complete
currently retained version snapshot:

```sh
ruby scripts/documentation/site.rb stage-correction \
  --source /tmp/UndoKit-guidance-checkout \
  --archive "$HOME/Library/Developer/Xcode/DerivedData/UndoKit/Documentation/Build/Products/Debug/UndoKit.doccarchive" \
  --producer /tmp/UndoKit-docs-producer.json \
  --release-provenance /tmp/UndoKit-0.2.0-manifest.json \
  --previous-snapshot /tmp/undokit-pages/versions/0.2.0 \
  --correction 'Correct the installation instructions.' \
  --output /tmp/undokit-docs-correction
shasum -a 256 /tmp/undokit-docs-correction/correction-provenance.json
```

The corrected artifact keeps `sourceCommit` as the released API source and adds
`documentationSourceCommit`, `releaseManifestSHA256`, `previousSnapshotSHA256`,
and `correctionNote`. Its producer identifies the actual documentation source
and archive. Staging prepares the visible escaped note, both source identities,
and cumulative `corrections.json` before hashing the final site. Promotion never
inserts or changes HTML after approval.

`correction-provenance.json` schema 1 binds `version`, `releaseSourceCommit`,
`releaseManifestSHA256`, `documentationSourceCommit`, `previousSnapshotSHA256`,
`note`, and the full corrected artifact manifest as `documentation`. Its own
SHA-256 is the correction identity. Review the generated content, source diff,
producer evidence, predecessor, and proposal, then explicitly supply that exact
reviewed digest. A JSON file alone cannot approve itself:

```sh
ruby scripts/documentation/site.rb promote \
  --artifact /tmp/undokit-docs-correction \
  --release-provenance /tmp/UndoKit-0.2.0-manifest.json \
  --source /tmp/UndoKit-guidance-checkout \
  --correction-provenance /tmp/undokit-docs-correction/correction-provenance.json \
  --approved-correction-sha256 <reviewed-64-character-SHA-256> \
  --destination /tmp/undokit-pages
```

Use the same approval/source options with `verify-release` and `update-latest`.
Promotion rechecks the complete Git restriction, original manifest digest,
proposal, actual producer/archive/site bytes, and predecessor. A stale proposal
is refused. Every prior complete version tree and its correction records remain
under `history/<version>/<previousSnapshotSHA256>/`. Successive corrections bind
their actual predecessor. Correcting an older release preserves the newer
latest pointer.

`publish-correction-provenance` takes those same artifact, source, release, and
approval options. After verifying the published release/tag and artifact, it
uploads only the additive asset
`UndoKit-<version>-docs-correction-<approved-SHA-256>.json`. It never replaces the
original candidate asset or another correction. An existing asset must match
exactly for an idempotent retry; differing bytes fail. Publishing this provenance
is an external write and belongs to the explicitly approved promotion process.

## Manual workflow and hosted acceptance

The repository workflow is `workflow_dispatch` only, using trusted workflow
checkout tooling separately from the selected source checkout:

- `stage` builds the selected full source SHA on the pinned Xcode runner,
  validates the generated release/development site, and uploads the unchanged
  candidate tree as a tar file in `undokit-docs-candidate`. Extract that file
  before inspection or preparation. Artifacts expire after 90 days.
- `stage-correction` additionally downloads the original release manifest,
  loads the retained predecessor from `documentation-snapshots`, enforces the
  restricted source diff, stages the complete correction, and prints its digest.
- `promote` downloads the fixed candidate by Actions run ID, verifies the
  published matching release/tag and original release asset, combines it with
  prior snapshots, updates latest, and deploys Pages.
- `promote-correction` requires the candidate run ID and the exact reviewed
  `correction_manifest_sha256` as explicit maintainer approval. It rechecks the
  clean documentation source and predecessor, copies the approved site unchanged,
  preserves history/latest rules, retains the additive correction asset, and
  deploys the same resulting tree.

Set `initialize_snapshots` only for the first deployment after confirming Pages
has no prior site. GitHub Pages must be enabled for this repository. No release
documentation or latest pointer should be deployed before the coordinated
release is approved.

The state branch is updated before Pages deployment. If upload, state commit,
or deployment fails, the previously hosted site remains authoritative; an
additive provenance asset or pending state commit may already exist. This is
incomplete publication, not a hosted pass. Inspect the failed step and retry
the same approved identity. Neither a successful local transform nor workflow
configuration establishes live hosting.

After deployment, verify installation guidance, navigation, search, symbol
links, assets, and a direct refresh of symbol/guide deep links under
`https://<owner>.github.io/UndoKit/versions/<version>/`. Retain the actual results
and any limitations with release evidence. Local export success alone does not
close the hosted acceptance requirement.
