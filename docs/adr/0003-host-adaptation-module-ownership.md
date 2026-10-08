<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Keep typed host adaptation inside UndoKit

UndoKit keeps public typed contracts and forwarding methods in `Interface/`, while codecs, validated registrations, version selection, typed delivery and outcome conversion, and opaque family routing belong to `Modules/HostAdaptation/`. This module owns the translation into the opaque transaction protocol; it does not own host meaning, actor-owned values, or authoritative outcome evidence. Callback context carries the transaction token and restoration origin so handlers can consult host receipts without receiving framework-private transaction stages. Mixed-family work requires paired host callbacks that provide atomic execution and outcome lookup.

Registration construction derives codec identities and configuration from the supplied codecs and validates operation identity and version mappings once. Actor and main-actor handlers retain their distinct isolation guarantees. Typed commands carry restoration origin and presentation metadata, and typed effects carry resource references. WriteKit adopts this interface for Manuscript changes and checkpoint state while keeping semantic validation and atomic receipts in its own adapter. This pre-alpha change preserves the existing transaction rules without retaining compatibility with earlier APIs or WriteKit payloads.
