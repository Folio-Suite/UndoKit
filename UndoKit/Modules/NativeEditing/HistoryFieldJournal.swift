// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Current field-only format. Unknown representations are preserved and refused.
struct HistoryFieldJournal: Codable {
    let format: Int
    let scope: UUID
    let workingIdentity: UUID
    let generation: UUID
    let field: String
    let mapping: String
    let codec: String
    let configuration: Data
    let version: Int
    let base: Data
    let revision: Data
    let proposed: Data
    let composing: Bool
    let prepared: HistoryPreparedEvidence.Command?
    let rejected: Bool
}

@MainActor final class HistoryNativeFieldState {
    let declaration: HistoryField<String>
    let journalURL: URL
    var base: HistoryFieldSnapshot<String>
    var proposed: String
    var composing = false
    var prepared: HistoryCommand?
    var rejected = false
    // A restored rejection has durable evidence but no current native callback history.
    var liveRejectionEditable = false
    var requiresExplicitDecision: Bool { requiresDecision && !liveRejectionEditable }
    var requiresDecision = false
    var compatible = true

    init(_ declaration: HistoryField<String>, snapshot: HistoryFieldSnapshot<String>, journalURL: URL) {
        self.declaration = declaration
        base = snapshot
        proposed = snapshot.value
        self.journalURL = journalURL
    }
    func matches(_ other: HistoryField<String>) -> Bool {
        declaration.operationIdentity == other.operationIdentity && declaration.mappingID == other.mappingID
            && declaration.version == other.version && declaration.codec.identifier == other.codec.identifier
            && declaration.codec.configuration == other.codec.configuration && declaration.session === other.session
    }
    func persist(configuration: HistorySessionConfiguration, generation: UUID) throws {
        if proposed == base.value && !composing && prepared == nil && !requiresDecision {
            try removeJournal()
            return
        }
        let baseData = try declaration.codec.encode(base.value)
        let proposedData = try declaration.codec.encode(proposed)
        guard baseData.count <= configuration.limits.maxPayloadBytes,
            base.revision.count <= configuration.limits.maxPayloadBytes,
            proposedData.count <= configuration.limits.maxPayloadBytes
        else {
            throw HistoryFailure(.capacity, stage: .preparation, disposition: .suspended)
        }
        if let prepared {
            var aggregate = prepared.fingerprint.count
            guard !prepared.members.isEmpty, prepared.members.count <= configuration.limits.maxMembers else {
                throw HistoryFailure(.capacity, stage: .preparation, disposition: .suspended)
            }
            for member in prepared.members { aggregate += member.payload.data.count }
            aggregate += prepared.presentation?.data.count ?? 0
            guard aggregate <= configuration.limits.maxPayloadBytes else {
                throw HistoryFailure(.capacity, stage: .preparation, disposition: .suspended)
            }
        }
        let journal = HistoryFieldJournal(
            format: 2, scope: configuration.scope,
            workingIdentity: configuration.workingIdentity, generation: generation,
            field: declaration.id, mapping: declaration.mappingID, codec: declaration.codec.identifier,
            configuration: declaration.codec.configuration, version: declaration.version,
            base: baseData, revision: base.revision, proposed: proposedData,
            composing: composing, prepared: prepared.map(HistoryPreparedEvidence.Command.init), rejected: rejected)
        try FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #else
        let options: Data.WritingOptions = .atomic
        #endif
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(journal)
        guard encoded.count <= configuration.limits.maxPayloadBytes * 4 else {
            throw HistoryFailure(.capacity, stage: .preparation, disposition: .suspended)
        }
        try encoded.write(to: journalURL, options: options)
    }
    func restore(configuration: HistorySessionConfiguration, generation: UUID) throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        compatible = false
        let size = try FileManager.default.attributesOfItem(atPath: journalURL.path)[.size] as? NSNumber
        guard (size?.int64Value ?? 0) <= Int64(configuration.limits.maxPayloadBytes) * 4 else {
            throw HistoryFailure(.capacity, stage: .preparation, disposition: .suspended)
        }
        let bytes = try Data(contentsOf: journalURL)
        guard bytes.count <= configuration.limits.maxPayloadBytes * 4 else {
            throw HistoryFailure(.capacity, stage: .preparation, disposition: .suspended)
        }
        let journal: HistoryFieldJournal
        do { journal = try JSONDecoder().decode(HistoryFieldJournal.self, from: bytes) } catch {
            throw HistoryFailure(.compatibility, stage: .preparation, disposition: .suspended)
        }
        guard journal.format == 2, journal.scope == configuration.scope,
            journal.workingIdentity == configuration.workingIdentity, journal.generation == generation,
            journal.field == declaration.id, journal.mapping == declaration.mappingID,
            journal.codec == declaration.codec.identifier, journal.configuration == declaration.codec.configuration,
            journal.version == declaration.version
        else {
            throw HistoryFailure(.compatibility, stage: .preparation, disposition: .suspended)
        }
        base = HistoryFieldSnapshot(value: try declaration.codec.decode(journal.base), revision: journal.revision)
        proposed = try declaration.codec.decode(journal.proposed)
        composing = journal.composing
        prepared = journal.prepared?.value
        rejected = journal.rejected
        liveRejectionEditable = false
        requiresDecision = true
        compatible = true
    }
    func removeJournal() throws {
        if FileManager.default.fileExists(atPath: journalURL.path) {
            try FileManager.default.removeItem(at: journalURL)
        }
    }
}
