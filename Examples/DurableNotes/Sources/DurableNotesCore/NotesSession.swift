// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit

/// The sample deliberately supports one writer per document, across processes.
/// Acquire ownership before creating or reading the authoritative host state.
private final class NotesOwnership {
    private var descriptor: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = Darwin.open(directory.appendingPathComponent("Owner.lock").path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
    }
    func release() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}

/// Shared portable example core. Shells own focus, editing groups and native barriers.
@MainActor public final class NotesSession {
    public let engine: HistoryEngine
    public let directory: URL
    private let host: DurableNotesHost
    private let ownership: NotesOwnership

    private init(engine: HistoryEngine, host: DurableNotesHost, directory: URL, ownership: NotesOwnership) {
        self.engine = engine; self.host = host; self.directory = directory; self.ownership = ownership
    }
    public static func open(at directory: URL) async throws -> NotesSession {
        let ownership = try NotesOwnership(directory: directory)
        let history = directory.appendingPathComponent("History.sqlite")
        let exists = FileManager.default.fileExists(atPath: history.path)
        let hostURL = directory.appendingPathComponent("Note.json")
        guard !exists || FileManager.default.fileExists(atPath: hostURL.path) else {
            throw HistoryFailure(.missingHistory, stage: .admission, disposition: .suspended)
        }
        let host = try DurableNotesHost(url: hostURL)
        let identity = await host.identity()
        let readout = await host.read()
        guard exists || readout.receiptCount == 0 else {
            throw HistoryFailure(.missingHistory, stage: .admission, disposition: .suspended)
        }
        let engine = try await HistoryEngine.open(at: history, scope: identity.scope,
            workingIdentity: identity.working, mode: exists ? .existing : .create, host: host)
        return NotesSession(engine: engine, host: host, directory: directory, ownership: ownership)
    }
    public func read() async -> NotesReadout { await host.read() }
    public func edit(title: String, body: String) async -> HistoryResult {
        do {
            guard let command = try await makeEdit(title: title, body: body) else { return .rejected }
            return await engine.submit(command)
        } catch { return .failure(HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)) }
    }
    private func makeEdit(title: String, body: String) async throws -> HistoryCommand? {
        let old = await host.read().note
        var changes: [NoteChange] = []
        if title != old.title { changes.append(NoteChange(field: .title, expected: old.title, replacement: title)) }
        if body != old.body { changes.append(NoteChange(field: .body, expected: old.body, replacement: body)) }
        guard !changes.isEmpty else { return nil }
        let members = try changes.map { HistoryMember(payload: try $0.payload()) }
        let intentEncoder = JSONEncoder()
        intentEncoder.outputFormatting = [.sortedKeys]
        let fingerprint = try intentEncoder.encode(changes)
        return HistoryCommand(fingerprint: fingerprint, members: members,
                presentation: HistoryPayload(family: "durable-notes.label", data: Data("Edit Note".utf8)),
                expectedGeneration: engine.snapshot.generation)
    }
    public func undo() async -> HistoryResult { await engine.undo(expectedGeneration: engine.snapshot.generation) }
    public func redo() async -> HistoryResult { await engine.redo(expectedGeneration: engine.snapshot.generation) }
    public func close() async throws { try await engine.close(); ownership.release() }
    public func rejectNextDelivery() async { await host.rejectNextDelivery() }
    public func delayNextDelivery() async { await host.delayNextDelivery() }
    public func resumeDelivery() async { await host.resumeDelivery() }
    public func isDeliveryDelayed() async -> Bool { await host.isDeliveryDelayed() }

    #if DEBUG
    /// Real history context-save failure after durable host acceptance; absent in Release.
    public func demonstrateFinalizationFailure(title: String, body: String) async -> HistoryResult {
        do {
            guard let command = try await makeEdit(title: title, body: body) else { return .rejected }
            return await engine.submitWithInjectedFinalizationFailure(command)
        } catch { return .failure(HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)) }
    }
    #endif
}
