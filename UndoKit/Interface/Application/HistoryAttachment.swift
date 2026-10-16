// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Connects one window or scene to a shared document session.
///
/// Retain the attachment with the presentation and expose its ``undoManager`` through
/// the platform responder route. Disconnecting it leaves document recovery owned by
/// ``HistorySessions``. See <doc:AppKitIntegration> and <doc:UIKitIntegration>.
@MainActor public final class HistoryAttachment {
    let session: HistorySession
    let id: UUID
    private let epoch: UUID
    private(set) var disconnected = false
    var platform: (any HistoryNativePlatformAdapter)?
    // MARK: - Native presentation

    /// The facade routing native live typing and durable document Undo/Redo.
    public var undoManager: UndoManager { platform?.undoManager ?? session.nativeCoordinator.undoManager }
    /// The shared session's current editing and recovery state.
    public var status: HistorySessionStatus { session.status }
    /// Whether this presentation participates in an unsettled native editing transaction.
    public var hasLiveTransaction: Bool { session.nativeCoordinator.hasLiveTransaction(attachment: id) }
    /// Set false when the presentation cannot safely access its document resources.
    public var isAvailable = true {
        didSet {
            platform?.available = isAvailable
            session.nativeCoordinator.refreshAvailability()
        }
    }
    init(session: HistorySession, id: UUID) {
        self.session = session
        self.id = id
        epoch = session.epoch
    }
    // MARK: - Explicit editing actions

    /// Settles native edits using the shared document operation.
    public func commit() async -> HistorySubmissionResult {
        guard !disconnected, epoch == session.epoch else { return retired() }
        return await session.settleEditing()
    }
    /// Requests Undo after the shared session settles native editing.
    public func undo() async -> HistorySubmissionResult {
        guard !disconnected, epoch == session.epoch else { return retired() }
        return await session.undo()
    }
    /// Requests Redo after the shared session settles native editing.
    public func redo() async -> HistorySubmissionResult {
        guard !disconnected, epoch == session.epoch else { return retired() }
        return await session.redo()
    }
    /// Applies the explicit retry decision for a retained draft.
    public func retryDraft() async -> HistorySubmissionResult {
        guard !disconnected, epoch == session.epoch else { return retired() }
        return await session.nativeCoordinator.retryDraft()
    }
    /// Applies the explicit discard decision without inventing a new accepted edit.
    public func discardDraft() async -> HistorySubmissionResult {
        guard !disconnected, epoch == session.epoch else { return retired() }
        return await session.nativeCoordinator.discardDraft()
    }
    /// Explicit certification that all unexplained callbacks and their domain effects were reviewed.
    public func reconcileNativeRegistrations() async throws {
        guard !disconnected, epoch == session.epoch else {
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
        try await session.nativeCoordinator.reconcileNativeRegistrations()
    }
    // MARK: - Presentation lifetime

    /// Releases this presentation's callbacks without closing the shared document session.
    /// Call explicit session closure when the document itself ends; a blocked close retains recovery.
    public func disconnect() {
        guard !disconnected else { return }
        // Captured recovery values and unexplained callback graphs remain owned by the session.
        session.nativeCoordinator.detach(attachment: id)
        disconnected = true
        platform = nil
        session.removeAttachment(id: id)
    }
    func requireCurrent() throws {
        guard !disconnected, epoch == session.epoch, session.status.phase != .closing, session.status.phase != .closed
        else {
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
    }
    private func retired() -> HistorySubmissionResult {
        .unexecuted(HistoryFailure(.identityConflict, stage: .admission, disposition: .usable))
    }
    isolated deinit { disconnect() }
}
