<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Typed operation contracts

Ordinary editing uses a `HistoryOperation<Command>` declaration and a session-bound
`HistoryCommands<Command>` handle. The declaration binds the actual handler,
stable family, current Command/effect codecs and canonical Intent Fingerprint.
Define these facts once during host setup; call sites submit typed values or
atomic groups. There is no mandatory checkpoint-state codec.

`HistoryOperationHandler` keeps execution on its actor.
`MainActorHistoryOperationHandler` supports Cocoa domain models. The host owns
validation, semantic no-ops, all-or-none group effects, authoritative receipts,
compensation, resource references and restoration meaning. Outcomes must name the
complete delivered member sequence. A mixed-family atomic executor requires a
matching authoritative outcome lookup; independent successful callbacks cannot
prove atomicity.

## Admission and stable intent

Ordinary Command values are transferable. A declaration's capture function freezes
intent synchronously before encoding can suspend; the host must explicitly copy
mutable reference content where necessary. Sendable conformance alone does not
make a Command immutable. Codecs run on the registered handler's actor.

The shared transaction owner reserves FIFO position and generation before async
encoding. Capacity counts encoding reservations. Cancellation, closure and
uncertainty terminalize waiting slots exactly once; late encoding cannot revive
them. Handles bind the actual registration, session epoch and History Generation.
A retired handle cannot target a replacement session or silently adopt its current
generation.

`HistorySubmissionResult` distinguishes unexecuted requests from delivered unresolved
work. An uncertain active operation stops queued followers explicitly. Recovery
consults original evidence and never automatically replays those followers.

## Actor-local advanced access

For non-Sendable domain values, declare `HistoryLocalOperation<Handler>` and obtain
a `HistoryLocalCommands<Handler>` handle. Invoke submission on that exact handler.
Canonical fingerprint and encoded bytes are captured synchronously on the owning
actor before the first suspension; only encoded values cross into the session.
This path uses the same admission owner and generation fences. It does not expose
an engine underneath an active ordinary session.

## Codecs and checkpoints

Codec identity and configuration are embedded with stored payloads. Current codec
versions and settings must match during delivery and inverse decoding. Unsupported
representations fail explicitly without mutating their bytes. This pre-release
interface has no old registration API, compatibility wrapper or legacy decoder
list.

Checkpoint and reconstruction support is separate from ordinary Command setup.
Hosts encode coherent historical state and interpret it using their declared
codecs, then use focused advanced reading/retention capabilities. A retained state
read does not restore live domain state. Restoration is a new host-validated
Command with explicit provenance.

For fully opaque integrations, `HistoryHost`, `HistoryStore` and `HistoryEngine`
remain the lower-level boundary. Opening another owner for a session's working
scope is a conflict. Native field settlement, ordinary typed submission and
session advanced mutations all respect the existing owner and its fences.
