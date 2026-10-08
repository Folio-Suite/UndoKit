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

Requirements are macOS 14 or later and Swift 6. From the repository root, run
`swift build`, `swift test`, and `scripts/check-consumer.sh` for changes that
affect package integration. The consumer check builds a separate executable
against the local package and opens a history store through the public API,
including its bundled Core Data model. CI runs package tests and this consumer
check with Xcode 27.

Scale other checks to the change. For documentation and templates, check local
links, copyright and license notices, and repository-specific references.
Persistence and recovery changes require meaningful preservation and failure
recovery checks; report limitations in runtime or consumer validation explicitly.

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
