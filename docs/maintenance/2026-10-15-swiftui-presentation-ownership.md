<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# SwiftUI editor presentation ownership

`NativeHistoryPresentationOwnership` is the shared policy beneath the public
SwiftUI editor wrappers. It keeps the current host and waiting hosts weakly,
ignores repeated attachment, removes detached waiters, and promotes the first
surviving waiter after the current host releases the editor. Dead weak entries
are pruned before promotion.

The AppKit and UIKit wrappers retain their weak editor-key registries and native
container implementations. Each adapter checks that the editor has no existing
superview before a new presentation may mount it, owns native mounting and
visibility behavior, and reports an unavailable presentation when another
parent already owns the editor. The shared policy never reparents an editor
from an unrelated native hierarchy.

Presentation teardown only releases the SwiftUI host. The stable document
owner continues to own the editor and History Session, so pending or rejected
draft recovery remains attached to that session. UIKit visibility callbacks
still require the callback's host to be current before changing temporary
detachment state; stale hosts cannot authorize a replacement presentation.

Focused source and consumer checks were added alongside the existing public
SwiftUI representable lifecycle coverage. Native producer and installed
consumer execution were intentionally left to the coordinated validation slot
because another work item owns the shared runner during this implementation.
