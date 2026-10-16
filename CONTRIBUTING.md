<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Working on UndoKit

UndoKit is a standalone Swift Package. Swift Package Manager is the authoritative
source build and test workflow; the Xcode project is an optional developer
harness.

## Community participation

Use [GitHub Issues](https://github.com/Folio-Suite/UndoKit/issues) for bug
reports and feature proposals. Discuss substantial behavior or architecture
changes before implementation. Use fictional examples and remove private
or sensitive data from screenshots and logs.

Report suspected security vulnerabilities privately through the process in
[SECURITY.md](SECURITY.md). Follow the [Code of Conduct](CODE_OF_CONDUCT.md)
in all project spaces.

For pull requests, explain the user need, summarize the change, link related
issues, and list the checks performed and any remaining validation limits.

## AI-assisted development

Engineering workflows are contributor-managed tools. A clone does not install
global skills or pin their versions. Contributors remain responsible for
reviewing, validating, and licensing AI-assisted work.

Repository integration lives in [AGENTS.md](AGENTS.md) and its linked
`docs/agents/` configuration. These files configure issue tracking, triage,
and domain-document consumption for skills such as triage, to-tickets,
to-spec, wayfinder, and domain-modeling when installed.

The configuration adapts [Matt Pocock's skills](https://github.com/mattpocock/skills).
Preserve his attribution and the [retained MIT notice](docs/agents/MATT-POCOCK-LICENSE)
when changing imported template material.

## Build and validation

Use Xcode 27.0 (27A266a), Apple Swift 6.4 and Swift 6 language mode with complete
concurrency checking. Run `ruby scripts/check-toolchain.rb`, then
`scripts/test-package.sh` and `scripts/test-package.sh -c release`.
Source/project targets explicitly use macOS 14 and
iOS/iPadOS 17 floors; macOS and simulator products cover arm64/x86_64, and
device products arm64. These settings are declarations, not hardware qualification.

For integration changes, run `scripts/check-consumer.sh --route both --platform
both --configuration Debug`, then the same command with `Release`. This checks
independent package/native consumers, grouped transactions, host receipts,
Undo/Redo and reopen on macOS and an installed iOS simulator app. The native
macOS framework must contain both architectures and the installed consumers
must carry the compiled model and privacy manifest. Build output belongs under
`~/Library/Developer/Xcode/DerivedData/UndoKit`, shared across checkouts.
Set `UNDOKIT_DERIVED_DATA` to override this root (for example on CI).
The package runner reuses a locked `Package` scratch directory; concurrent
package runs wait for its owner rather than sharing mutable build state.
Consumer runs reuse locked build databases under `Consumers/Build` and remove
temporary stores/projects on completion; `--keep` retains stores, generated
projects and reports, without duplicating the shared build caches. Build-product
paths in reports describe that run and may be overwritten by the next run.
Use Xcode's default Derived Data location in workspace settings. Avoid
checkout-local build caches and retain large consumer artifacts only when needed.
To use a particular installed iOS runtime, add `--device UDID` with `--platform
both` or `ios-simulator`. The consumer runner refuses other booted simulators,
boots the selected device only when needed, and shuts it down on exit only if
it booted it. It never deletes a supplied device. Each launch uses fresh isolated
stores and reports. Without `--device`, CI retains its latest-runtime selection
and creates and deletes its own simulator. For the tracked iPadOS 27 simulator
failure (FB25165352), use the available 26.5 device for local runtime checks.
CI repeats both configurations. Debug-only injected failure cases do not exist
in Release; all ordinary durability and consumer cases run in both. Clean builds
covering declared architectures satisfy CPU coverage without dedicated Intel
execution. Floor/current OS behavior, specific unresolved physical-device
questions and binary distribution acceptance remain separate release gates;
see [the qualification policy](docs/release-qualification.md).

Scale other checks to the change. For documentation and templates, check local
links, copyright and license notices, and repository-specific references.
Persistence and recovery changes require meaningful preservation and failure
recovery checks; report limitations in runtime or consumer validation explicitly.

For DocC integration examples, run `ruby scripts/check-documentation-examples.rb
--configuration Debug` and repeat with `Release`. The checker compiles the actual
Markdown snippets for Mac and iOS Simulator; on Mac it also verifies the persisted
rename/Undo/Redo/reopen walkthrough. See [documentation upkeep and local
preview](docs/documentation-site.md) for DocC builds and evidence limits.

## Versioning and dependencies

The source package begins at `0.1.0` with independent release tags. Consumer
requirements follow the consumer's stage: development allows updates within the
selected major version (including across minor versions during `0.x`); beta
allows updates within the selected minor version; release engineering requires
an exact version. Commit resolved dependency records at every stage. Stage
transitions are deliberate and are not inferred from UndoKit's version number.
Pre-alpha API and storage compatibility remain bounded by the documented
contracts; a dependency range is not a promise of persisted-format migration.

## Licensing

UndoKit retains the MIT license and `the Folio Project` copyright holder from
its Folio source. Preserve original notices and creation years when importing
files. Use the appropriate creation year for new project-authored files:

- `SPDX-FileCopyrightText: 2026 the Folio Project`
- `SPDX-License-Identifier: MIT`

Use the file format's comment syntax. Keep shebangs, XML declarations, Xcode
encoding markers, and Markdown front matter in their required positions.
Project-owned formats without comments, such as JSON, are covered by the
repository's [MIT license](LICENSE); do not create license sidecars.

Xcode FILEHEADER templates configure notices for new source files; preserve
the framework's shared IDETemplateMacros.plist when migrating its project.
These templates do not rewrite existing notices or update years on each build.

Environment-generated files do not require copyright or SPDX notices or license
sidecars. This includes Xcode-generated or maintained Core Data model XML,
storyboards, project files, shared schemes, and generated source. Accept the
development environment's serialization changes without restoring notices it
removes. This exemption does not remove attribution or license obligations for
imported third-party material.

Preserve upstream authorship and license terms for imported skills and the
Contributor Covenant in CODE_OF_CONDUCT.md.
