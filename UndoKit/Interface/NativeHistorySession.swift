// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Creation is explicit; subsequent reopening never creates missing host/history data.
public enum NativeHistoryOpenMode: Equatable, Sendable { case create, existing }

/// A host value paired with an opaque domain revision. Equal values do not prove equal revisions.
public struct NativeDraftSnapshot<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value
    public let revision: Data
    public init(value: Value, revision: Data) { self.value = value; self.revision = revision }
}

/// Construct without I/O. The collection retains the lease before acquisition begins.
/// Failed acquisition retains every acquired resource until complete `close()` succeeds.
@MainActor public protocol NativeHistoryLease: AnyObject {
    associatedtype Draft: Equatable & Sendable
    var history: HistoryEngine? { get }
    func open(_ mode: NativeHistoryOpenMode) async throws
    /// Idempotent complete closure: history first, then host ownership.
    func close() async throws
    func readDraft() async throws -> NativeDraftSnapshot<Draft>
    /// Prepare against this exact base; never reread and silently rebase the proposed intent.
    func makeCommand(from base: NativeDraftSnapshot<Draft>, to proposed: Draft, generation: UUID) async throws -> HistoryCommand?
}

public enum NativeHistoryPhase: Equatable, Sendable { case opening, ready, busy, suspended, closing, closed, blocked }
public struct NativeHistoryStatus: Equatable, Sendable {
    public let phase: NativeHistoryPhase
    public let canUndo: Bool
    public let canRedo: Bool
    public let issue: HistoryFailure?
    public let requiresDraftDecision: Bool
    public var isEditingBlocked: Bool { phase != .ready || requiresDraftDecision }
}

public struct NativeDraftCapture<Value: Equatable & Sendable>: Sendable {
    public let value: Value
    public let isComposing: Bool
    public init(value: Value, isComposing: Bool = false) { self.value = value; self.isComposing = isComposing }
}

/// A presentation attachment, never the recovery owner. Disconnecting releases all callbacks.
@MainActor public final class NativeHistoryConnection {
    private var disconnectAction: (() -> Void)?
    init(_ disconnect: @escaping () -> Void) { disconnectAction = disconnect }
    public func disconnect() { let action = disconnectAction; disconnectAction = nil; action?() }
    isolated deinit { disconnectAction?() }
}

public struct NativeHistorySessionEntry: Sendable {
    public let documentURL: URL
    public let status: NativeHistoryStatus
    public let hasConnection: Bool
}

/// Explicit app-owned retention of connected, draining and blocked document sessions.
@MainActor public final class NativeHistorySessions<Lease: NativeHistoryLease> {
    private var sessions: [URL: NativeHistorySession<Lease>] = [:]
    public var entriesDidChange: (() -> Void)?
    public init() {}
    public var entries: [NativeHistorySessionEntry] {
        sessions.values.map { NativeHistorySessionEntry(documentURL: $0.documentURL, status: $0.status, hasConnection: $0.hasConnection) }
            .sorted { $0.documentURL.path < $1.documentURL.path }
    }
    public func session(for documentURL: URL) -> NativeHistorySession<Lease>? { sessions[canonical(documentURL)] }
    /// Returns the retained owner before invoking the factory, including after failed closure.
    public func open(documentURL: URL, mode: NativeHistoryOpenMode,
                     codec: HistoryCodec<Lease.Draft>, codecVersion: Int = 1, draftURL: URL,
                     makeLease: () -> Lease) async -> NativeHistorySession<Lease> {
        let key = canonical(documentURL)
        if let existing = sessions[key] { await existing.waitForOpening(); return existing }
        let session = NativeHistorySession(documentURL: key, lease: makeLease(), codec: codec,
            codecVersion: codecVersion, draftURL: draftURL)
        sessions[key] = session
        session.ownerChanged = { [weak self, weak session] in
            guard let self, let session, self.sessions[key] === session else { return }
            if session.status.phase == .closed && !session.hasConnection { self.sessions.removeValue(forKey: key) }
            self.entriesDidChange?()
        }
        entriesDidChange?()
        await session.open(mode)
        return session
    }
    /// Only a still-retained owner may reopen. A retired reference cannot race its replacement.
    public func reopen(_ session: NativeHistorySession<Lease>) async {
        guard sessions[session.documentURL] === session, session.status.phase == .closed else { return }
        await session.open(.existing)
    }
    public func closeAll() async { for session in Array(sessions.values) { await session.close() } }
    private func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: false)
    }
}

/// Safe native editing, durable submission and complete lease closure behind one interface.
/// The collection owns recovery; a presentation connection owns no document resources.
@MainActor public final class NativeHistorySession<Lease: NativeHistoryLease> {
    private let editing: NativeEditingSession<Lease>
    public var documentURL: URL { editing.documentURL }
    public var undoManager: UndoManager { editing.undoManager }
    public var draft: Lease.Draft? { editing.draft }
    public var status: NativeHistoryStatus { editing.status }
    public var hasConnection: Bool { editing.hasConnection }
    public var statusDidChange: ((NativeHistoryStatus) -> Void)? {
        get { editing.statusDidChange }
        set { editing.statusDidChange = newValue }
    }
    fileprivate var ownerChanged: (() -> Void)? {
        get { editing.ownerChanged }
        set { editing.ownerChanged = newValue }
    }
    fileprivate init(documentURL: URL, lease: Lease, codec: HistoryCodec<Lease.Draft>, codecVersion: Int, draftURL: URL) {
        editing = NativeEditingSession(documentURL: documentURL, lease: lease, codec: codec, codecVersion: codecVersion, draftURL: draftURL)
    }
    fileprivate func open(_ mode: NativeHistoryOpenMode) async { await editing.open(mode) }
    fileprivate func waitForOpening() async { await editing.waitForOpening() }
    /// Callbacks receive a weakly retained presentation owner as their first argument.
    /// Do not capture the same owner strongly inside these callbacks.
    public func connect<Owner: AnyObject>(owner: Owner,
        captureDraft: @escaping @MainActor (Owner) -> NativeDraftCapture<Lease.Draft>?,
        draftDidChange: @escaping @MainActor (Owner, Lease.Draft) -> Void,
        statusDidChange: (@MainActor (Owner, NativeHistoryStatus) -> Void)? = nil) throws -> NativeHistoryConnection {
        try editing.connect(owner: owner, captureDraft: captureDraft, draftDidChange: draftDidChange, statusDidChange: statusDidChange)
    }
    /// Captures values and composition synchronously before any asynchronous admission.
    public func updateDraft(_ proposed: Lease.Draft, isComposing: Bool = false) throws { try editing.updateDraft(proposed, isComposing: isComposing) }
    public func submit(_ command: HistoryCommand) async -> HistoryResult { await editing.submit(command) }
    public func commit() async -> HistoryResult { await editing.commit() }
    public func retryDraft() async -> HistoryResult { await editing.retryDraft() }
    public func discardDraft() async -> HistoryResult { await editing.discardDraft() }
    public func undo() async -> HistoryResult { await editing.undo() }
    public func redo() async -> HistoryResult { await editing.redo() }
    /// Advanced recovery only: the host must first identify every unexplained native
    /// registration and reconcile its authored values. This explicit certification permits
    /// clearing native callbacks after capturing the connected value; it executes no Command.
    /// A fully closed lease is reacquired before capture. Prepared intent and pending draft
    /// decisions are preserved, and newer registrations during recovery require another review.
    /// Supported AppKit/UIKit registration classification belongs to the forthcoming bindings.
    public func reconcileNativeRegistrations() async throws { try await editing.reconcileNativeRegistrations() }
    #if DEBUG
    /// Demonstrates the existing production accepted-finalization save failure.
    /// Durable host acceptance may already exist; use retryDraft to reconcile exact intent.
    public func demonstrateFinalizationFailure() async -> HistoryResult { await editing.demonstrateFinalizationFailure() }
    #endif
    /// Drains admitted work, preserves unsettled draft, then completely closes the lease.
    /// Failure remains discoverable in the collection; call again to retry closure.
    public func close() async { await editing.close() }
}
