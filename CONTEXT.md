# UndoKit

UndoKit provides shared history concepts for applications with different ownership,
retention, and presentation policies.

## Language

**History Scope**:
A stable, host-defined identity for an independently owned history. It outlives
individual editing contexts and application launches; multiple editing contexts
may participate in the same scope.
_Avoid_: Window, process, editing context

**Command**:
An identified, host-submitted request to perform a semantic operation; the host
owns the determination that a change is needed. Retrying an unresolved request
preserves its identity without establishing acceptance.
_Avoid_: Action, accepted change

**Accepted Outcome**:
The host-authoritative result establishing a Command's accepted semantic effect.
It is distinct from evidence that a Command was merely requested or recorded in
History.
_Avoid_: Command, submission

**Action**:
An accepted semantic change resulting from a Command. Accepted Undo and Redo
operations also produce Actions with explicit relationships to earlier changes;
failed or unresolved Commands may need recovery evidence without producing an Action.
_Avoid_: Command, attempt, Revision

**Undo Group**:
One user-visible Undo/Redo step comprising one or more accepted Actions within a
single History Scope, reversed or reapplied as a whole without a partial semantic
result. The constituent Actions retain their individual identities.
_Avoid_: Command, Action

**History**:
The retained record of accepted Actions and, when enabled, historical states
within a History Scope. It can include material that is no longer available
through ordinary Undo or Redo.
_Avoid_: Undo availability, redo availability

**Historical State**:
A coherent host-defined domain state represented in History, including the
dependencies the host identifies as necessary to interpret it. Its semantic
meaning and completeness belong to the host; its representation need not be a
complete duplicate of the host's data.
_Avoid_: Recipe Revision, Proposed Revision

**History Branch**:
A retained alternative continuation from shared earlier History within one
History Scope. UndoKit owns its structural relationships; the host supplies the
associated data and chooses its presentation.
_Avoid_: History Scope, Recipe Revision

**Checkpoint**:
A host-designated, optionally named reference to a coherent Historical State,
available when checkpoint capability is requested. Retaining a Checkpoint
preserves the data that state requires; hosts determine how Checkpoints are used.
_Avoid_: Backup, History Branch

**Undo/Redo Position**:
The place from which ordinary Undo/Redo operates in a History Scope's current
ordering, distinct from the newest historical record or a state being browsed.
The host may select a different branch and position; changes to domain state
require an accepted host operation.
_Avoid_: Latest Action, browsing selection

**Undo/Redo Availability**:
Eligibility to perform Undo or Redo in a History Scope. Availability can change
independently of what the History retains; losing availability alone does not
require deleting retained History.
_Avoid_: History retention

**Suspension**:
Temporary loss of Undo/Redo Availability while an outcome, dependency, or
eligibility question is unresolved. Successful reconciliation can lift it.
_Avoid_: Invalidation, Pruning

**Invalidation**:
Retirement of affected Undo/Redo eligibility without necessarily removing the
retained History. Coincidental return to earlier data values does not automatically
restore eligibility; retained material may instead support a new Command.
_Avoid_: Suspension, Pruning

**Pruning**:
Removal of historical data under an authorized retention policy, preserving
anything still required by current content, retained History, or pending recovery.
_Avoid_: Invalidation, Suspension

**History Capabilities**:
The history behaviors supported by UndoKit and requested by a host. They establish
which choices are available to the host's History Policies.
_Avoid_: History Policy

**History Policy**:
Host-owned rules governing recording, retention, and use of supported capabilities
within a History Scope, subject to UndoKit's storage safeguards. Defaults may be
established at initialization and supported policy choices may change during use.
_Avoid_: History Capabilities
