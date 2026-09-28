<!--
SPDX-FileCopyrightText: 2026 Justin Croonenberghs
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# ``UndoKit``

An independent framework scaffold for durable application history.

## Overview

UndoKit is developed in the Folio monorepo for use by Folio and other applications.
Its imported vocabulary, research, and design decisions describe the intended
history capabilities. The current implementation exports framework identity only;
durable storage, acceptance, recovery, and native Undo routing remain future work.

The host owns semantic meaning, validation, compensation, authoritative accepted
outcomes, and policy. UndoKit's planned responsibility is history structure and
storage safeguards. It has no dependency on Folio's document model.
