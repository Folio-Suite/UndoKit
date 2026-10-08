<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# UndoKit source and split history

UndoKit's implementation and design records were developed in the Folio
repository before the standalone repository was created. This repository
preserves that work and continues its development as an independent Swift
Package.

The initial package extraction was taken from Folio source commit
`5d252a9e791717f598ab3a30aa6fc530d9c0b984`. The split was merged while
preserving the independent repository's initial commit
`d3ebec289285af283fdcc5779711154f3d538966`; the merge commit is
`5e6437ada5574d72eb418c6805b029489fb7ea34`.

The preserved design inventory in [`docs/imported-design/`](docs/imported-design/)
contains the imported research, issue snapshot, checksums, and recoverable
historical Git bundle. Those artifacts document provenance; current source,
tests, and accepted decisions in this repository govern ongoing development.

Historical Folio issue references remain attached to the original decisions
they describe. Folio's historical tracker is not the tracker for new work;
future reports and proposals belong in the
[UndoKit issue tracker](https://github.com/Folio-Suite/UndoKit/issues).
The retained prototypes under `prototypes/` are isolated evidence and are not
the production package implementation.
