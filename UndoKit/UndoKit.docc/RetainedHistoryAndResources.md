# Retained history, checkpoints and resources

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Browsing retained History does not move ordinary Undo/Redo position.

## Read narrowly

Give browsers ``HistoryReading`` and policy owners ``HistoryRetentionManaging``.
Metadata pages do not decode every state. A Checkpoint is a host-designated opaque
state reference; the host owns semantic completeness and required dependencies.
A new edit after Undo can retire ordinary Redo eligibility while retaining the
displaced continuation's history.

Use a ``HistoryRecoveryPlan`` to obtain a coherent bounded sequence of opaque
accepted-effect transitions. Release the plan when complete or cancelled. The
host retrieves required codecs/resources, reconstructs an isolated state and
validates it. Reading or reconstruction does not restore live content. To adopt
the result, submit a new Command carrying its restoration origin.

## Protect what recovery needs

State protection and detailed-history protection are distinct promises. A
Checkpoint or state hold preserves state dependencies; a detailed hold can retain
the transition material needed for further browsing/reconstruction. Resource
references identify host-owned bytes; UndoKit does not copy or interpret their
meaning. Preserve required host codecs and resources while retained history,
active plans or pending work can still reference them.

Run bounded retention/consolidation maintenance under the selected host policy.
Whole Undo Groups must remain coherent; ordinary depth is not a count of individual
members. Physical resource cleanup belongs to the store-wide fence because other
scopes can retain the same host objects. Do not infer that loss of Undo availability
permits deleting retained History or shared resources.

## Recording and continuity

Recording-Off changes are undoable in the open session, but the first accepted
Off change creates a gap that cannot be crossed to older ordinary Actions.
Re-enabling recording adopts a coherent host baseline. Earlier retained states
may still be read under their existing codec/resource requirements.

Clearing settled history establishes a new generation. A quarantined unresolved
reset requires independent knowledge of current domain state and an explicit
host decision; it is not ordinary error handling. Delayed requests bound to a
retired generation must be refused before delivery.

## Topics

- ``HistoryReading``
- ``HistoryRetentionManaging``
- ``HistoryRecoveryPlan``
- ``HistoryStore``
