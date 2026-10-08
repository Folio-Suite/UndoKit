<!--
SPDX-FileCopyrightText: 2026 Matt Pocock
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Issue tracker: GitHub

Issues and specs live in Folio-Suite/UndoKit GitHub Issues.
Use the gh CLI. Pass --repo Folio-Suite/UndoKit until the Git
remote is configured; afterward, verify the inferred repository.

## Conventions

- Create: gh issue create --repo Folio-Suite/UndoKit
  --title "..." --body-file <file>
- Read: gh issue view <number> --repo Folio-Suite/UndoKit --comments
- List: gh issue list --repo Folio-Suite/UndoKit --state open
  --json number,title,body,labels,assignees
- Comment: gh issue comment <number> --repo Folio-Suite/UndoKit
  --body-file <file>
- Label: gh issue edit <number> --repo Folio-Suite/UndoKit
  --add-label "..." or --remove-label "..."
- Close: gh issue close <number> --repo Folio-Suite/UndoKit

Use files for multiline bodies. Read relevant comments and labels
before acting on a ticket.

## Pull requests as a triage surface

PRs as a request surface: no.

GitHub issues and pull requests share a number space.
Resolve ambiguous references before acting.

## Skill operations

“Publish to the issue tracker” means create a GitHub issue.
“Fetch the relevant ticket” means read the issue and its comments.

## Wayfinding operations

- Map: one issue labelled wayfinder:map, with Notes,
  Decisions-so-far, and Fog sections.
- Children: link tickets as native GitHub sub-issues. If unavailable,
  use a task list in the map and “Part of #<map>” in each child.
  Use wayfinder:<type> labels for research, prototype, grilling,
  and task tickets.
- Blocking: use native GitHub issue dependencies. Dependency writes
  require the blocker’s numeric database id, not its issue number
  or node id. If unavailable, use a “Blocked by: #...” line.
- Frontier: inspect open map children in map order. Choose the first
  unassigned ticket with no open blockers, checking current dependency
  state rather than relying on an older snapshot.
- Claim: assign the selected ticket to the driving developer before
  implementation.
- Resolve: record the answer on the ticket, close it, and add a concise
  result and link to the map’s Decisions-so-far section.

## Attribution

Adapted from [Matt Pocock's skill setup templates](https://github.com/mattpocock/skills).
See the retained [MIT notice](MATT-POCOCK-LICENSE).
