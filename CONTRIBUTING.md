<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Working on UndoKit

UndoKit is being extracted from Folio into this standalone repository.
Build and test instructions will accompany the framework migration; this
initial repository setup does not yet contain the framework or its tests.

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

## Validation

Scale checks to the change. For repository documentation and templates, check
local links, copyright and license notices, and repository-specific references.
When framework code arrives, use its documented build and test workflow.
Persistence and recovery changes require meaningful preservation and failure
recovery checks; report limitations in runtime or consumer validation explicitly.

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
