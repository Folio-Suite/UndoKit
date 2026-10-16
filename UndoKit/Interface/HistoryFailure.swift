// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Broad failure categories independent of a host's domain vocabulary.
public enum HistoryFailureCause: String, Sendable {
    /// History persistence or finalization failed; consult stage and disposition before retrying.
    case storage
    /// An input, queue, plan or store safety bound would be exceeded.
    case capacity
    /// A Command, generation, working identity or registered location has a conflicting binding.
    case identityConflict
    /// The request violates structural requirements before semantic execution.
    case invalidInput
    /// Host evidence violates the complete-group acceptance contract.
    case hostProtocol
    /// The authoritative effect cannot yet be established.
    case unresolved
    /// A preceding native editing transaction was rejected; this dependent request was not delivered.
    case prerequisiteRejected
    /// Work, closure, maintenance or prohibited reentry prevents admission now.
    case busy
    /// A schema, codec, encoded envelope or stored model cannot be interpreted safely.
    case compatibility
    /// A cancellable pre-delivery operation or read was cancelled.
    case cancelled
    /// A host expected registered history, but no database exists at that location.
    case missingHistory
    /// Existing bytes are not a readable SQLite history database.
    case corruptHistory
    /// The expected location exists but cannot currently be opened.
    case unavailableStore
}

/// The transaction stage at which completion failed.
public enum HistoryFailureStage: String, Sendable {
    /// Admission, input validation or scheduling did not complete.
    case admission
    /// Durable preparation or the pre-delivery transition failed.
    case preparation
    /// The host delivery boundary failed to establish ordinary completion.
    case delivery
    /// Authoritative outcome lookup or interrupted-work recovery failed.
    case reconciliation
    /// History acceptance, rejection closure or related relationships could not finalize.
    case finalization
}
/// Whether this scope can continue accepting semantic mutations.
public enum HistoryScopeDisposition: String, Sendable {
    /// Safe closure or a pre-effect refusal permits subsequent independent requests.
    case usable
    /// Resolve evidence, prerequisites or finalization before allowing new semantic delivery.
    case suspended
    /// This generation cannot safely continue; the host must explicitly adopt coherent current state.
    case resetRequired
}

/// A typed failure. Underlying text is diagnostic and never changes the disposition.
public struct HistoryFailure: Error, Equatable, Sendable {
    /// Application-neutral category for diagnosis and recovery selection.
    public let cause: HistoryFailureCause
    /// Boundary at which successful framework completion stopped.
    public let stage: HistoryFailureStage
    /// Whether ordinary history use can continue; this outranks diagnostic text.
    public let disposition: HistoryScopeDisposition
    /// Optional diagnostic detail; it is neither a semantic rejection nor repair authorization.
    public let underlyingDescription: String?

    /// Creates a failure description. It does not alter scope state or reconcile domain effects.
    /// A host reports pre-effect failure only when no semantic effect is authoritative;
    /// possible effects require outcome lookup rather than classification as rejection.
    public init(
        _ cause: HistoryFailureCause, stage: HistoryFailureStage,
        disposition: HistoryScopeDisposition, underlyingDescription: String? = nil
    ) {
        self.cause = cause
        self.stage = stage
        self.disposition = disposition
        self.underlyingDescription = underlyingDescription
    }
}
