<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# UndoKit preservation and incorporation

UndoKit was imported from `ctwelve/UndoKit` on 2026-09-27 at source commit `5ca57fd54f91ad754ca3d0d8398f67745a7b5be7`. Its original MIT license and attribution to Justin Croonenberghs are retained. Folio is now the development and tracker home for its Swift implementation, primarily serving Folio and secondarily KitchenMemory while preserving generic module boundaries.

The maintainer explicitly authorized deletion of the original remote after preservation. The [design inventory](docs/imported-design/README.md) preserves all useful source/design records and maps unresolved issues to Folio. The complete ten-commit Git history is recoverable from the verified bundle; issues, comments, events and native relationships are retained in JSON with original identities. Checksums accompany the preserved artifacts. The separate original local checkout is retained.

[Folio build adaptations](README.md#integration-with-folio) remain documented. The current framework is a scaffold, not a production history engine. Historical Objective-C/XCFramework research remains useful provenance, while external distribution is deferred until after a working Folio Suite 1.0.
