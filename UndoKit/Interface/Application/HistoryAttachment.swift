// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// A presentation attached to a shared History Session. The application collection owns recovery.
@MainActor public final class HistoryAttachment {
    let session: HistorySession
    let id: UUID
    private let epoch: UUID
    private(set) var disconnected = false
    var platform: (any HistoryNativePlatformAdapter)?
    public var undoManager: UndoManager { platform?.undoManager ?? session.nativeCoordinator.undoManager }
    public var status: HistorySessionStatus { session.status }
    public var hasLiveTransaction: Bool { session.nativeCoordinator.hasLiveTransaction(attachment: id) }
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
    public func commit() async -> HistorySubmissionResult {
        guard !disconnected, epoch == session.epoch else { return retired() }
        return await session.settleEditing()
    }
    public func undo() async -> HistorySubmissionResult {
        guard !disconnected, epoch == session.epoch else { return retired() }
        return await session.undo()
    }
    public func redo() async -> HistorySubmissionResult {
        guard !disconnected, epoch == session.epoch else { return retired() }
        return await session.redo()
    }
    public func retryDraft() async -> HistorySubmissionResult {
        guard !disconnected, epoch == session.epoch else { return retired() }
        return await session.nativeCoordinator.retryDraft()
    }
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
    public func disconnect() {
        guard !disconnected else { return }
        // Failed safeguarding leaves the coordinator and callback owner retained by the session.
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
