# ``UndoKit``

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

An independent framework scaffold for durable application history.

## Overview

UndoKit is developed in the Folio monorepo as a framework boundary that may serve Folio and other applications. Its imported vocabulary, research, and design decisions describe intended history capabilities; they are not evidence that those capabilities are implemented.

The accepted [durable-acceptance contract](../../docs/durable-acceptance-contract.md) defines the planned host outcome, interruption, compensation, retention and recovery boundary. It does not add a public operation to the current scaffold.

## Current support

UndoKit currently exports framework identity and version symbols. It has no public history operations or durable-history behavior. Its independence from Folio domain models is an architectural boundary for the intended framework, not a claim of a completed history engine.

## Public interface and hosting

Swift clients use `import UndoKit`. The retained umbrella header exposes framework identity and version symbols only; external Objective-C API distribution is deferred. Apps and Kits ship as a coordinated Suite version; mixed versions are unsupported, and independent binary compatibility is not promised.

## Limitations

Durable storage, operation acceptance, recovery, branching, checkpoints, and native Undo routing are not implemented. The accepted ownership boundary leaves semantic meaning, validation, compensation, accepted outcomes, recovery evidence, and recording or retention policy with the host. UndoKit is intended to supply generic history structure and storage safeguards without depending on Folio's document model.
