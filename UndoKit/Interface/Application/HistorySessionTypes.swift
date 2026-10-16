// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Framework-owned history placement and the host identities associated with it.
public struct HistorySessionConfiguration: Sendable {
    public let historyURL: URL
    public let scope: UUID
    public let workingIdentity: UUID
    public let mode: HistoryOpenMode
    public let scopeMode: HistoryScopeOpenMode
    public let limits: HistoryLimits
    public let journalDirectory: URL

    public init(
        historyURL: URL, scope: UUID, workingIdentity: UUID,
        mode: HistoryOpenMode, scopeMode: HistoryScopeOpenMode? = nil,
        limits: HistoryLimits = HistoryLimits(),
        journalDirectory: URL? = nil
    ) {
        self.historyURL = historyURL.standardizedFileURL.resolvingSymlinksInPath()
        self.scope = scope
        self.workingIdentity = workingIdentity
        self.mode = mode
        if let scopeMode {
            self.scopeMode = scopeMode
        } else {
            switch mode {
            case .create: self.scopeMode = .create
            case .existing, .independentCopy: self.scopeMode = .existing
            }
        }
        self.limits = limits
        self.journalDirectory =
            (journalDirectory
            ?? self.historyURL.deletingLastPathComponent()
            .appendingPathComponent("HistoryDrafts", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// Host acquisition performs no framework history-store bookkeeping.
/// Construction must not acquire resources: the collection retains the lease first.
@MainActor public protocol HistoryHostLease: AnyObject {
    func open(_ mode: HistoryOpenMode) async throws
    /// Release domain ownership only after UndoKit has closed its own resources.
    func close() async throws
}

public struct HistorySessionSetup: Sendable {
    public let configuration: HistorySessionConfiguration
    public let operations: [AnyHistoryOperation]
    public let atomicGroupExecutor: HistoryHostRegistry.AtomicGroupExecutor?
    public let atomicOutcomeLookup: HistoryHostRegistry.AtomicOutcomeLookup?
    public init(
        configuration: HistorySessionConfiguration, operations: [AnyHistoryOperation],
        atomicGroupExecutor: HistoryHostRegistry.AtomicGroupExecutor? = nil,
        atomicOutcomeLookup: HistoryHostRegistry.AtomicOutcomeLookup? = nil
    ) {
        self.configuration = configuration
        self.operations = operations
        self.atomicGroupExecutor = atomicGroupExecutor
        self.atomicOutcomeLookup = atomicOutcomeLookup
    }
}

public enum HistorySessionPhase: Equatable, Sendable {
    case opening, ready, busy, suspended, closing, closed, blocked
}

public struct HistorySessionStatus: Equatable, Sendable {
    public let phase: HistorySessionPhase
    public let canUndo: Bool
    public let canRedo: Bool
    public let issue: HistoryFailure?
    public let requiresDraftDecision: Bool
    public var isEditingBlocked: Bool { phase != .ready || requiresDraftDecision }
    public init(
        phase: HistorySessionPhase, canUndo: Bool, canRedo: Bool,
        issue: HistoryFailure?, requiresDraftDecision: Bool
    ) {
        self.phase = phase
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.issue = issue
        self.requiresDraftDecision = requiresDraftDecision
    }
}

/// Delivery certainty is explicit: unexecuted requests must be submitted as fresh intent.
public enum HistorySubmissionResult: Equatable, Sendable {
    case accepted(HistoryReceipt)
    case rejected
    case unexecuted(HistoryFailure)
    /// Delivery completed with a proved usable failure, without unresolved host effects.
    case failed(HistoryFailure)
    /// Prepared or delivered work still requires authoritative recovery or finalization.
    case unresolved(HistoryFailure)

    init(_ result: HistoryResult) {
        switch result {
        case .accepted(let receipt): self = .accepted(receipt)
        case .rejected: self = .rejected
        case .failure(let failure):
            if failure.stage == .admission || failure.stage == .preparation {
                self = .unexecuted(failure)
            } else if failure.disposition != .usable {
                self = .unresolved(failure)
            } else {
                self = .failed(failure)
            }
        }
    }
}

public struct HistorySessionEntry: Sendable {
    public let documentURL: URL
    public let status: HistorySessionStatus
    public let attachmentCount: Int
}

/// Optional host metadata derived once from a family's typed intent.
public struct HistoryOperationMetadata: Sendable {
    public let restorationOrigin: UUID?
    public let presentation: HistoryPayload?
    public init(restorationOrigin: UUID? = nil, presentation: HistoryPayload? = nil) {
        self.restorationOrigin = restorationOrigin
        self.presentation = presentation
    }
}
