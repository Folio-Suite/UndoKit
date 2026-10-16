<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Get started with UndoKit

Start with a small document and a working native editor. The
[DocC walkthrough](../UndoKit/UndoKit.docc/FirstUndoGroup.md) opens a shared
History Session, submits a typed edit, then exercises Undo, Redo and reopen.
It uses the app-owned Durable Notes types so you can run the complete host and
inspect its persisted state and outcome receipts.

## Pick your presentation

| App | Integration guide | Complete example |
| --- | --- | --- |
| AppKit | [Window and text-view wiring](../UndoKit/UndoKit.docc/Integration/AppKitIntegration.md) | [Durable Notes](../Examples/DurableNotes/README.md) |
| UIKit | [Controller and scene wiring](../UndoKit/UndoKit.docc/Integration/UIKitIntegration.md) | [iPhone/iPad](../Examples/DurableNotes/UIKit/README.md) |
| SwiftUI | [Stable owners and native-backed editors](../UndoKit/UndoKit.docc/Integration/SwiftUIIntegration.md) | [Mac](../Examples/DurableNotes/SwiftUIApp/README.md), [iPhone/iPad](../Examples/DurableNotes/SwiftUI/README.md) |

From the repository root, launch the AppKit example:

```sh
ruby scripts/check-toolchain.rb
ruby scripts/run-durable-notes.rb --launch
```

Apply its grouped example, Undo and Redo, then type in the body. Live typing uses
native Undo/Redo; **Commit typing** settles a durable Undo Group. Closing and
reopening returns to the accepted note without replaying its effects. Each
platform README includes interactive exercises and its own runner commands.

## Bring your own model

[Connect your model](../UndoKit/UndoKit.docc/Integration/HostingYourModel.md)
explains operation declarations, typed handles, field mappings and the host lease.
Your app stores primary data and authoritative receipts atomically. UndoKit owns
the separate history database, draft journal, ordering and recovery coordination.

Keep one application-owned `HistorySessions` collection and one stable session
per working document scope. Each window or scene attaches to that session and
uses its native UndoManager route. A disappearing presentation does not close the
shared document or discard a pending effect.

When opening known history, use `.existing`. Missing/corrupt original data must be
preserved and refused, rather than silently replaced with empty history. Read
[recovery and storage](../UndoKit/UndoKit.docc/RecoveryAndStorage.md) before adding
close/reopen, explicit draft decisions or unavailable-storage handling.

## Continue when you need more

- [Installation routes](installation.md): dynamic package, native framework and XCFramework.
- [AppKit binding contract](appkit-history-binding.md) and [UIKit binding contract](uikit-history-binding.md): detailed native behavior and acceptance exercises.
- [Retained-history reconstruction](history-reconstruction.md) and [retention](history-retention-contract.md): checkpoints, browsing and safe cleanup.
- [Compatibility](history-compatibility.md) and [qualification](release-qualification.md): persistence promises and actual OS/runtime evidence.

The examples use programmatic native input as well as manual exercises. An
injected finalization failure plus graceful reopen demonstrates that path; it
does not certify abrupt termination, physical file protection, real hardware
keyboard input or IME behavior. Follow each runner's exact source/configuration
and independent readback evidence. This guide does not establish release readiness.
