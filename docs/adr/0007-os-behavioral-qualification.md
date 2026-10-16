<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# OS behavior takes precedence over CPU execution coverage

Accepted with the maintainer on 2026-10-15 in
[#57](https://github.com/Folio-Suite/UndoKit/issues/57). UndoKit's current
Swift/Cocoa API, Core Data persistence and absence of low-level CPU optimizations
or cross-application binary wire formats justify accepting clean declared-architecture
builds and independent consumer evidence without dedicated Intel execution.
Actual floor/current OS behavioral testing remains required; physical hardware
answers a specific behavioral question that available simulation or virtualization
cannot resolve, rather than filling a blanket device matrix.

This amends ADR 0005's qualification paragraph and the architecture/hardware
execution clauses of tracker decisions #5/#8. The platform matrix, behavioral
preservation requirements, artifact checks and explicit publication approval
remain. See [the qualification policy](../release-qualification.md) for evidence
requirements and triggers for reconsideration.
