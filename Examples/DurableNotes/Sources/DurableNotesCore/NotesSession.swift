// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit

/// The sample deliberately supports one writer per document, across processes.
/// Acquire ownership before creating or reading the authoritative host state.
final class NotesOwnership {
    private var descriptor: Int32
    init(directory: URL, createDirectory: Bool = true) throws {
        if createDirectory {
            #if os(iOS)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            #else
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #endif
        }
        descriptor = Darwin.open(directory.appendingPathComponent("Owner.lock").path,
            createDirectory ? O_RDWR | O_CREAT : O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
    }
    func release() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}

/// Portable host facade using the same typed History Session as native presentations.
@MainActor public final class NotesSession {
    public let history: HistorySession
    public let directory: URL
    private let lease: NotesDocumentLease
    private let owners: HistorySessions

    private init(history: HistorySession, lease: NotesDocumentLease, owners: HistorySessions) {
        self.history = history; self.lease = lease; self.owners = owners; directory = lease.directory
    }
    public static func openExisting(at directory: URL) async throws -> NotesSession {
        try await open(at: directory, existingOnly: true)
    }
    public static func open(at directory: URL) async throws -> NotesSession {
        try await open(at: directory, existingOnly: false)
    }
    private static func open(at directory: URL, existingOnly: Bool) async throws -> NotesSession {
        let exists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("History.sqlite").path)
        let hostExists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("Note.json").path)
        guard !existingOnly || (exists && hostExists), exists == hostExists else {
            throw HistoryFailure(.missingHistory, stage: .admission, disposition: .suspended)
        }
        let mode: HistoryOpenMode = exists ? .existing : .create
        let owners = HistorySessions()
        let lease = NotesDocumentLease(directory: directory)
        let history = await owners.open(documentURL: directory, mode: mode, lease: lease) {
            try await lease.setup(mode: mode)
        }
        guard history.status.phase == .ready else {
            let failure = history.status.issue ?? HistoryFailure(.storage, stage: .admission, disposition: .suspended)
            await history.close()
            throw failure
        }
        return NotesSession(history: history, lease: lease, owners: owners)
    }
    public func read() async throws -> NotesReadout { try await lease.read() }
    public func edit(title: String, body: String) async -> HistorySubmissionResult {
        await lease.edit(title: title, body: body, in: history)
    }
    public func undo() async -> HistorySubmissionResult { await history.undo() }
    public func redo() async -> HistorySubmissionResult { await history.redo() }
    public func close() async throws {
        await history.close()
        guard history.status.phase == .closed else {
            throw history.status.issue ?? HistoryFailure(.storage, stage: .finalization, disposition: .suspended)
        }
    }
    public func rejectNextDelivery() async { await lease.rejectNextDelivery() }
    public func delayNextDelivery() async { await lease.delayNextDelivery() }
    public func resumeDelivery() async { await lease.resumeDelivery() }
    public func isDeliveryDelayed() async -> Bool { await lease.isDeliveryDelayed() }

    #if DEBUG
    public func demonstrateFinalizationFailure(title: String, body: String) async -> HistorySubmissionResult {
        await lease.demonstrateFinalizationFailure(title: title, body: body, in: history)
    }
    #endif
}
