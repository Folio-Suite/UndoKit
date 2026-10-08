<!--
SPDX-FileCopyrightText: 2026 Matt Pocock
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Domain docs

## Before exploring

Read root CONTEXT.md and relevant decisions in docs/adr/.

If either is absent, proceed silently. Create domain documentation
when terminology or decisions are resolved through domain-modeling.

## Layout

UndoKit is a single-context repository:

- CONTEXT.md: domain glossary
- docs/adr/: architectural decisions

## Vocabulary

Use domain terms as defined in CONTEXT.md in issues, proposals,
code, and tests. Reconsider unfamiliar synonyms; surface genuine
glossary gaps for domain-modeling.

## Decision conflicts

When a proposal contradicts an accepted ADR, identify the decision
and explain why it should be reopened before overriding it.

## Attribution

Adapted from [Matt Pocock's skill setup templates](https://github.com/mattpocock/skills).
See the retained [MIT notice](MATT-POCOCK-LICENSE).
