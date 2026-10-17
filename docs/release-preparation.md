<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Preparing an UndoKit preview candidate

`0.2.0` is the planned next preview. Preparation retains a candidate for
qualification; it does not qualify it, create a tag, publish a GitHub release,
deploy Pages, or approve promotion. Actual signed preparation
requires approved Apple Distribution publisher and certificate details and
secure access to its private key (#24). The maintainer-approved publisher is
Justin Croonenberghs under team `FT9KDL728H`; the
[signing verification record](signing-identity.md) records the checked certificate
and actual secure-timestamp probe. Recheck availability, validity and approval
for each preparation. An Apple Development certificate cannot substitute.
Development project signing settings do not establish release authority.

The accepted contracts are [binary installation](https://github.com/Folio-Suite/UndoKit/issues/7#issuecomment-6104427419),
[release identity](https://github.com/Folio-Suite/UndoKit/issues/9), and
[public onboarding](https://github.com/Folio-Suite/UndoKit/issues/10#issuecomment-6104631432).
Qualification remains governed by [the acceptance gates](https://github.com/Folio-Suite/UndoKit/issues/8).

On 2026-10-17, the maintainer moved the release producer from Xcode 27.0
(27A266a) to Xcode 27.1 (27A9275). The installed Swift compiler remains Apple
Swift 6.4 (`swiftlang-6.4.0.34.1`, embedded clang `2100.3.34.1`); standalone
clang remains `2100.3.34.2`. This supersedes the producer pin in ADR 0005 for
new candidates. Historical reports and the retained October 15 candidate keep
their original identities. The subsequent framework refactor and revised
documentation require a new candidate and applicable requalification.

## Inputs and authority

The [qualification policy](release-qualification.md) accepts declared-architecture
builds without dedicated Intel execution and retains floor/current OS behavioral
tests. Hardware is used for specific unresolved behaviors. Preparing a candidate
does not establish those results. If revised release documentation affects
qualification, prepare a new candidate rather than changing retained bytes.

Select an exact clean source commit containing the intended release changes.
Use the pinned Xcode 27.1 (27A9275), Apple Swift 6.4 producer. Marketing version
is `0.2.0`; choose a positive integer framework build larger than every previously
published framework build. Published source tag `0.1.0` records build `1`; build
`2` is the initial `0.2.0` plan. Unpublished attempts may reuse this planned
version/build; their signed ZIP hashes and candidate identities remain distinct.

Prepare these inputs outside the source checkout:

- The retained output directory from `scripts/assemble-xcframework.rb`, including
  `provenance.json`, all three original `.xcarchive` outputs and original dSYMs,
  and the unsigned `UndoKit.xcframework`. Keep that entire directory unchanged.
- A release documentation artifact from `scripts/documentation/site.rb` (#22):
  `manifest.json`, `producer.json`, `archive/` and `site/`. It must describe
  `0.2.0`, the same clean source commit and pinned Xcode/Swift producer, channel `release`,
  and base path `/UndoKit/versions/0.2.0/`. Both original DocC archive and staged
  output are retained exactly; preparation performs no documentation build.
  Retain full standalone clang output independently: this Xcode reports
  `Apple clang version 21.0.0 (clang-2100.3.34.2)`, while the pinned Swift compiler
  identifies its embedded clang as `2100.3.34.1`. These are distinct evidence.
- A maintainer-approved publisher record. This is an explicit local input,
  supplied through the maintainer's trusted process; repository signing settings
  are not substituted for approval. The record contains no private key.
- A fresh maintainer-reviewed published identity inventory. Refresh it from
  actual published releases, tags and retained release evidence immediately before
  preparation. An offline inventory cannot establish current remote state;
  verify it again during approval and promotion. The tool retains and hashes it.

Stage documentation with the `Versioned documentation` Actions workflow
(`documentation.yml`), operation `stage`, the selected full `source_commit`,
version `0.2.0` and channel `release`. Download its retained output without
rebuilding it:

```sh
gh run download DOCS_STAGE_RUN_ID --repo Folio-Suite/UndoKit \
  --name undokit-docs-candidate --dir /absolute/path/to/retained/documentation-transport
mkdir /absolute/path/to/retained/documentation
tar -xf /absolute/path/to/retained/documentation-transport/undokit-docs-candidate.tar \
  -C /absolute/path/to/retained/documentation
```

The extracted directory is the `--docs` input: `manifest.json`,
`producer.json`, `archive/`, and `site/` are at its root. Its manifest's
`producerPath` and `producerSHA256` bind the original producer record;
`sourceCommit`, `sourceDirty: false`, full toolchain and `producerCommand`
bind the documentation build. Archive/site tree hashes bind retained output.
Keep the selected Actions run ID as staging evidence, and copy downloaded bytes
to durable retention before the Actions artifact expires. Candidate preparation
checks this initial release artifact against the binary's exact source identity.

The publisher JSON uses this schema (replace all illustrative values):

```json
{
  "schemaVersion": 1,
  "publisher": "Apple Distribution: Approved Publisher (TEAMID1234)",
  "teamIdentifier": "TEAMID1234",
  "certificateSHA256": "64 lowercase hexadecimal characters from the approved DER certificate",
  "approvedBy": "Maintainer identity",
  "approvalEvidence": "Trusted approval record reference"
}
```

The tool locates this exact public certificate in accessible keychains, verifies
its SHA-256 fingerprint, Apple Distribution common name, team and validity,
and requires its matching usable codesigning identity/private key. It does not
import certificates, export keys, configure keychains, or acquire signing access.
The assembled signature must satisfy an Apple trust anchor requirement, the
same approved leaf certificate and team, and strict signature verification.
A secure `Timestamp=` must be present in the verified signature's metadata;
local signing time is insufficient. Raw verification output and the extracted
public signing certificate are retained.

The inventory JSON has schema version `1`, repository `Folio-Suite/UndoKit`,
`observedAtUTC` in ISO 8601 form, a nonempty `evidence` reference and a `published`
array. Each published binary identity includes three-part `version`, positive
integer-string `frameworkBuildNumber`, full lowercase `sourceCommit`, and
64-character lowercase `archiveSHA256`. For a historical source-only release, retain `installationRoute: "source-only"`,
matching `tag`/`version`, `sourceCommit` and an `evidence` reference. Set
`archiveSHA256` to `null`; retain a known published source framework build in
`frameworkBuildNumber`, or `null` only when explicitly unknown. Both binary
and known source release builds are reserved for monotonicity. For example,
`0.1.0` peels to `9e5cf63b7ba89247de8cedd9308329e74c13f82a`, and
`git show 0.1.0:Project.xcconfig` records `CURRENT_PROJECT_VERSION = 1`, so its
source-only record uses build `"1"` and archive checksum `null`. This preserves
published identities without inventing a binary release. Never use an empty inventory to bypass
known published identities. The selected version must be absent from published
identities and from local tags. Preparation never fetches, edits, or deletes tags.

## Deliberate preparation

Run the assembly command from the selected clean checkout first:

```sh
scripts/assemble-xcframework.rb --version 0.2.0 --build-number BUILD --run-id UNIQUE
```

After producing and staging the matching documentation artifact, prepare from
those fixed inputs. Use a fresh output path outside the checkout and inputs:

```sh
scripts/release/candidate.rb prepare \
  --source /absolute/path/to/clean/UndoKit \
  --commit FULL_40_CHARACTER_COMMIT \
  --version 0.2.0 --build-number BUILD \
  --assembly /absolute/path/to/retained/assembly \
  --docs /absolute/path/to/retained/documentation \
  --publisher-approval /absolute/path/to/approved-publisher.json \
  --published-inventory /absolute/path/to/published-identities.json \
  --output /absolute/path/to/new/candidate
```

The command checks source, archive and documentation identities, copies original
inputs, inspects platform variants/interfaces/resources and binary/dSYM UUID
pairing, and signs a separate copy of the finalized assembled XCFramework.
It verifies signing and checks that framework contents still match, creates the
single distributable ZIP once with `ditto --keepParent`, and computes its SHA-256.
It then extracts that ZIP to verify its sole root is `UndoKit.xcframework` and
that it carries those exact signed bytes, including embedded dSYMs.

No byte-identical signed rebuild promise is made. A second preparation uses a
new output directory and produces separately identified candidate evidence.
The build/archive inputs are never signed in place or removed on failure.

## Retained evidence and later verification

A successful directory includes:

- `UndoKit.xcframework`, the finalized signed bundle;
- `UndoKit-0.2.0-buildBUILD.xcframework.zip` and `SHA256SUMS`;
- `manifest.json` and `manifest.sha256`;
- `inputs/assembly/` with unchanged producer evidence, original archives and dSYMs;
- `inputs/documentation/` with unchanged documentation archive, site and provenance;
- the approved publisher record, published inventory, signing log and public
  signing certificate under `inputs/`.

The schema 1 manifest records version/build/source/planned tag, exact producer
configuration and procedure, measured variants/interfaces/model/privacy hashes
and binary/dSYM UUIDs, signer identity/fingerprint/secure timestamp evidence,
original producer provenance, documentation identity, ZIP checksum and a
candidate ID derived from source/version/build/ZIP/documentation identities.
Its initial `qualificationStatus` is `not-yet-qualified`.

Copy the entire candidate directory into retained storage. Verify after copying,
before qualification, and before promotion:

```sh
scripts/release/candidate.rb verify --candidate /absolute/path/to/candidate
```

Verification reads the retained bytes and verifies the signature, approved
publisher and secure timestamp again. Original human-readable timestamp output
remains retained provenance; locale or timezone display changes do not change
candidate identity. Verification still requires a secure timestamp in the actual
verified signature, the same signed bundle bytes, and approved leaf/team identity.
A local `Signed Time=` value cannot substitute. Temporary extraction/certificate inspection
uses an isolated temporary directory. Verification does not rebuild, sign,
repack, rewrite manifests or repair a modified candidate. Checksums and manifest
hashes identify bytes; approval must bind their trusted values separately.

Use the signed candidate's bundle directly for binary consumer checks:

```sh
scripts/check-binary-consumer.rb \
  --xcframework /absolute/path/to/candidate/UndoKit.xcframework
```

The consumer detects the sibling candidate `manifest.json` and invokes the full
candidate verifier before inspecting/building a consumer. Conflicting unsigned
`provenance.json` and candidate manifests are rejected. Original unsigned
assembly directories continue to use their original `provenance.json` route.
Consumer evidence records which manifest kind supplied the source and artifact
identity, its SHA-256, and the candidate ID/ZIP identity when applicable.
Metadata hashes alone do not establish publisher authentication. A successful
real signed candidate consumer run remains required when release signing access
is available; synthetic external-tool tests do not satisfy it.

Attach qualification results and maintainer approval as separate records binding
`candidateID`, manifest SHA-256 and ZIP SHA-256. Do not append results to the
candidate manifest or change retained documentation. A relevant source, artifact
or documentation change requires a new preparation and applicable requalification.
Promotion must use the exact approved ZIP, documentation output and source
commit without rebuilding, re-signing or recompressing. Publication and live
verification remain separate maintainer-controlled work (#28/#29). Publish the
unchanged candidate `manifest.json` bytes as the GitHub release asset
`UndoKit-0.2.0-manifest.json` (general form `UndoKit-<version>-manifest.json`).
That exact asset name is the versioned documentation promotion workflow's
release-provenance input. Changing an upload filename does not change the
approved manifest bytes or its SHA-256; preserve both.

An output path inside the source or either original input is rejected before
creating any directory or diagnostic file, including through symlink parents.
Other failed attempts retain `preparation-failure.json` and any copied artifacts,
partial signed bundle, certificate evidence and ZIP already produced. If final
verification fails, an attempted manifest is retained as `unverified-manifest.json`.
A failed attempt is rejected by `verify`; use a new output directory when retrying.
Inspect and preserve original inputs and failure evidence before cleanup.

## Tooling checks and limits

Run `ruby scripts/release/candidate_test.rb`. The tests exercise the public CLI,
retained hashes, actual ZIP creation/extraction, failure preservation and refusal
paths using controlled filesystem/Git fixtures. Synthetic external `security`,
`codesign`, `plutil` and `xcrun` executables isolate signing and platform inspection.
Those tests do **not** establish an actual Apple Distribution signature, trusted
signing access, secure timestamp service response, archive validity, consumer
acceptance or hardware qualification. A real retained signed preparation with
the approved publisher is still required before #25 can be completed.
