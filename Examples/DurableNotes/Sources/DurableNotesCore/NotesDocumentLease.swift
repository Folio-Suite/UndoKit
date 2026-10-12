// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit

/// Domain-only adapter: atomic Note.json effects and receipts, plus exclusive ownership.
/// Construction performs no I/O. NativeHistorySessions retains this lease before opening.
@MainActor public final class NotesDocumentLease: NativeHistoryLease {
    public let directory: URL
    public private(set) var history: HistoryEngine?
    private var store: HistoryStore?
    private var host: DurableNotesHost?
    private var ownership: NotesOwnership?

    public init(directory: URL) { self.directory = directory }
    public func open(_ mode: NativeHistoryOpenMode) async throws {
        guard ownership == nil, store == nil, history == nil else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        let historyURL = directory.appendingPathComponent("History.sqlite")
        let hostURL = directory.appendingPathComponent("Note.json")
        let historyExists = FileManager.default.fileExists(atPath: historyURL.path)
        let hostExists = FileManager.default.fileExists(atPath: hostURL.path)
        if mode == .existing {
            guard historyExists, hostExists else {
                throw HistoryFailure(.missingHistory, stage: .admission, disposition: .suspended)
            }
        } else {
            guard !historyExists, !hostExists else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
        }
        ownership = try NotesOwnership(directory: directory, createDirectory: mode == .create)
        let host = try DurableNotesHost(url: hostURL, createIfMissing: mode == .create)
        self.host = host
        let identity = await host.identity()
        // Retain the physical store before scope acquisition; no convenience-open cleanup can
        // hide partially acquired resources from the complete lease's close operation.
        let store = try await HistoryStore.open(at: historyURL, workingIdentity: identity.working,
            mode: mode == .create ? .create : .existing)
        self.store = store
        history = try await store.openScope(identity.scope, mode: mode == .create ? .create : .existing, host: host)
    }
    public func close() async throws {
        try await history?.close()
        try await store?.close()
        history = nil; store = nil; host = nil
        ownership?.release(); ownership = nil
    }
    public func read() async throws -> NotesReadout {
        guard let host else { throw HistoryFailure(.missingHistory, stage: .admission, disposition: .usable) }
        return await host.read()
    }
    public func readDraft() async throws -> NativeDraftSnapshot<Note> {
        let readout = try await read()
        // This durable token changes for Forward/Undo/Redo, even when values happen to coincide.
        return NativeDraftSnapshot(value: readout.note, revision: Data(String(readout.applicationCount).utf8))
    }
    public func makeCommand(from base: NativeDraftSnapshot<Note>, to proposed: Note, generation: UUID) async throws -> HistoryCommand? {
        var changes: [NoteChange] = []
        if proposed.title != base.value.title {
            changes.append(NoteChange(field: .title, expected: base.value.title, replacement: proposed.title))
        }
        if proposed.body != base.value.body {
            changes.append(NoteChange(field: .body, expected: base.value.body, replacement: proposed.body))
        }
        guard !changes.isEmpty else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return HistoryCommand(fingerprint: try encoder.encode(changes),
            members: try changes.map { HistoryMember(payload: try $0.payload()) },
            presentation: HistoryPayload(family: "durable-notes.label", data: Data("Edit Note".utf8)),
            expectedGeneration: generation)
    }
    public func rejectNextDelivery() async { await host?.rejectNextDelivery() }
    public func delayNextDelivery() async { await host?.delayNextDelivery() }
    public func resumeDelivery() async { await host?.resumeDelivery() }
    public func isDeliveryDelayed() async -> Bool { await host?.isDeliveryDelayed() ?? false }
}
