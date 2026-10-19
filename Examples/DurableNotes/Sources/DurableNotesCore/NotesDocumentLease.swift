// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit

/// Domain ownership and atomic Note.json effects/receipts. UndoKit owns its stores.
@MainActor public final class NotesDocumentLease: HistoryHostLease {
    public let directory: URL
    public var isOpen: Bool { host != nil }
    private var host: DurableNotesHost?
    private var ownership: NotesOwnership?
    private var operation: HistoryOperation<NoteChange>?

    public init(directory: URL) { self.directory = directory }
    public func open(_ mode: HistoryOpenMode) async throws {
        guard ownership == nil, host == nil else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        let creating: Bool
        switch mode {
        case .create: creating = true
        case .existing: creating = false
        case .independentCopy: throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        @unknown default: throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        let historyExists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("History.sqlite").path)
        let hostURL = directory.appendingPathComponent("Note.json")
        let hostExists = FileManager.default.fileExists(atPath: hostURL.path)
        if !creating {
            guard historyExists, hostExists else {
                throw HistoryFailure(.missingHistory, stage: .admission, disposition: .suspended)
            }
        } else {
            guard !historyExists, !hostExists else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
        }
        ownership = try NotesOwnership(directory: directory, createDirectory: creating)
        let host = try DurableNotesHost(url: hostURL, createIfMissing: creating)
        self.host = host
        operation = try HistoryOperation(operation: "durable-notes.change", commandCodec: .json(),
            effectCodec: .json(), handler: host, fingerprint: { changes in
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                return try encoder.encode(changes)
            }, metadata: { changes in
                HistoryOperationMetadata(presentation: HistoryPayload(
                    family: "durable-notes.action", data: Data((changes.count == 1 ? changes[0].field.rawValue : "note").utf8)))
            })
    }
    public func openSession(in owners: HistorySessions, mode: HistoryOpenMode) async -> HistorySession {
        await owners.open(documentURL: directory, mode: mode, lease: self) { [self] in
            try await setup(mode: mode)
        }
    }
    public func setup(mode: HistoryOpenMode) async throws -> HistorySessionSetup {
        guard let host, let operation else {
            throw HistoryFailure(.missingHistory, stage: .admission, disposition: .suspended)
        }
        let identity = await host.identity()
        return HistorySessionSetup(configuration: HistorySessionConfiguration(
            historyURL: directory.appendingPathComponent("History.sqlite"), scope: identity.scope,
            workingIdentity: identity.working, mode: mode), operations: [operation.erased])
    }
    public func close() async throws {
        operation = nil; host = nil
        ownership?.release(); ownership = nil
    }
    public func read() async throws -> NotesReadout {
        guard let host else { throw HistoryFailure(.missingHistory, stage: .admission, disposition: .usable) }
        return await host.read()
    }
    public func commands(in session: HistorySession) throws -> HistoryCommands<NoteChange> {
        guard let operation else { throw HistoryFailure(.missingHistory, stage: .admission, disposition: .usable) }
        return try session.commands(for: operation)
    }
    public func field(_ field: NoteChange.Field, in session: HistorySession) throws -> HistoryField<String> {
        HistoryField(id: field.rawValue, mappingID: "durable-notes.\(field.rawValue).v1", codec: .json(),
            commands: try commands(in: session), read: { [self] in
                let readout = try await read()
                return HistoryFieldSnapshot(value: field == .title ? readout.note.title : readout.note.body,
                    revision: Data(String(readout.applicationCount).utf8))
            }, makeCommands: { base, proposed in
                base.value == proposed ? [] : [NoteChange(field: field, expected: base.value, replacement: proposed)]
            })
    }
    public func changes(title: String, body: String) async throws -> [NoteChange] {
        let old = try await read().note
        var changes: [NoteChange] = []
        if title != old.title { changes.append(NoteChange(field: .title, expected: old.title, replacement: title)) }
        if body != old.body { changes.append(NoteChange(field: .body, expected: old.body, replacement: body)) }
        return changes
    }
    public func edit(title: String, body: String, in session: HistorySession) async -> HistorySubmissionResult {
        do {
            let changes = try await changes(title: title, body: body)
            guard !changes.isEmpty else { return .rejected }
            return try await commands(in: session).submitGroup(changes)
        } catch let failure as HistoryFailure { return .unexecuted(failure) }
        catch { return .unexecuted(HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)) }
    }
    #if DEBUG
    public func demonstrateFinalizationFailure(title: String, body: String, in session: HistorySession) async -> HistorySubmissionResult {
        do {
            let changes = try await changes(title: title, body: body)
            // This explicit Debug demonstration replaces live input with its captured typed intent.
            _ = await session.discardDraft()
            return try await commands(in: session).submitGroupWithInjectedFinalizationFailure(changes)
        } catch let failure as HistoryFailure { return .unexecuted(failure) }
        catch { return .unexecuted(HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)) }
    }
    #endif
    public func rejectNextDelivery() async { await host?.rejectNextDelivery() }
    public func delayNextDelivery() async { await host?.delayNextDelivery() }
    public func resumeDelivery() async { await host?.resumeDelivery() }
    public func isDeliveryDelayed() async -> Bool { await host?.isDeliveryDelayed() ?? false }
}
