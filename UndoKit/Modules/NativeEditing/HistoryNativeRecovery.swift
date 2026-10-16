// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

extension HistoryNativeCoordinator {
    func safeguardForClose() async throws {
        closing = true
        resumeComposition()
        if let transaction { try capture(transaction) }
        for state in fields.values {
            if state.proposed != state.base.value || state.composing || state.prepared != nil {
                state.requiresDecision = true
            }
            try persist(state)
        }
        guard !unknown else { throw failure(.hostProtocol, suspended: true) }
    }
    func reopened() {
        closing = false
        refreshAvailability()
    }
    func retireGeneration() throws {
        guard transaction == nil, !unknown, unboundJournals.isEmpty,
            fields.values.allSatisfy({ $0.prepared == nil && !$0.requiresDecision && $0.proposed == $0.base.value })
        else {
            throw failure(.busy)
        }
        adapters.values.compactMap(\.value).forEach { $0.detach() }
        adapters.removeAll()
        fields.removeAll()
        settled.removeAll()
        refreshAvailability()
    }
    func historyDidClose() throws {
        guard !unknown else { throw failure(.hostProtocol, suspended: true) }
        if let transaction { retire(transaction) }
        adapters.values.compactMap(\.value).forEach { $0.detach() }
        adapters.removeAll()
        fields.removeAll()
        settled.removeAll()
    }

    func journalDirectory(_ configuration: HistorySessionConfiguration) -> URL {
        configuration.journalDirectory.appendingPathComponent(
            configuration.workingIdentity.uuidString, isDirectory: true
        )
        .appendingPathComponent(configuration.scope.uuidString, isDirectory: true)
    }
    func inspectJournals(configuration: HistorySessionConfiguration, generation: UUID) throws {
        let directory = journalDirectory(configuration)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            do {
                let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
                guard (size?.int64Value ?? 0) <= Int64(configuration.limits.maxPayloadBytes) * 4 else {
                    throw failure(.capacity, suspended: true)
                }
                let data = try Data(contentsOf: url)
                guard data.count <= configuration.limits.maxPayloadBytes * 4 else {
                    throw failure(.capacity, suspended: true)
                }
                let journal: HistoryFieldJournal
                do { journal = try JSONDecoder().decode(HistoryFieldJournal.self, from: data) } catch {
                    throw failure(.compatibility, suspended: true)
                }
                guard journal.format == 2, journal.scope == configuration.scope,
                    journal.workingIdentity == configuration.workingIdentity, journal.generation == generation,
                    !journal.field.isEmpty, journal.field.utf8.count <= 100, !journal.mapping.isEmpty,
                    journal.mapping.utf8.count <= 256, !journal.codec.isEmpty, journal.version > 0,
                    url.lastPathComponent == journal.field.utf8.map({ String(format: "%02x", $0) }).joined() + ".json"
                else { throw failure(.compatibility, suspended: true) }
                if fields[journal.field] == nil { unboundJournals.insert(journal.field) }
            } catch {
                block(error)
                throw error
            }
        }
        refreshAvailability()
    }
    var canRetryLiveRejection: Bool {
        guard !unknown, issue == nil, unboundJournals.isEmpty, let transaction,
            let state = fields[transaction.field], state.rejected, state.liveRejectionEditable, state.compatible
        else { return false }
        return !fields.values.contains { $0 !== state && $0.requiresDecision }
    }
    func admissionClosing() {
        closing = true
        resumeComposition()
    }
    func admissionFailure() -> HistoryFailure? {
        if unknown { return failure(.hostProtocol, suspended: true) }
        if let issue { return issue }
        if !unboundJournals.isEmpty || fields.values.contains(where: \.requiresExplicitDecision) {
            return failure(.unresolved, suspended: true)
        }
        return nil
    }
    func restoreTransaction(attachment: UUID, control: UUID, field: String) {
        guard transaction == nil, fields[field]?.requiresDecision == true,
            let adapter = adapters[attachment]?.value
        else { return }
        transaction = Transaction(id: UUID(), attachment: attachment, control: control, field: field, adapter: adapter)
    }
    func liveManager(attachment: UUID, control: UUID?) -> UndoManager? {
        guard let transaction, transaction.attachment == attachment else { return nil }
        if let control, control != transaction.control { return nil }
        return transaction.adapter.liveManager(control: transaction.control)
    }
    func nativeRegistrationObserved() {
        unknown = true
        registrationEpoch &+= 1
        refreshAvailability()
    }
    func prepareExplicitInverse() {
        guard canRetryLiveRejection, !session.snapshot.hasPending, let previous = transaction else { return }
        settled.removeAll()
        transaction = Transaction(
            id: UUID(), attachment: previous.attachment, control: previous.control,
            field: previous.field, adapter: previous.adapter)
    }
    func retryDraft() async -> HistorySubmissionResult {
        guard let engine = session.engine, !engine.transaction.isActive else {
            return .unexecuted(failure(.busy))
        }
        guard !unknown, !closing, !session.snapshot.hasPending, fields.values.allSatisfy(\.compatible) else {
            return await session.settleEditing()
        }
        issue = nil
        guard let transaction, let state = fields[transaction.field],
            unboundJournals.isEmpty, !fields.values.contains(where: { $0 !== state && $0.requiresDecision })
        else {
            return .unexecuted(failure(.unresolved, suspended: true))
        }
        settled.removeAll()
        self.transaction = Transaction(
            id: UUID(), attachment: transaction.attachment, control: transaction.control,
            field: transaction.field, adapter: transaction.adapter)
        state.composing = false
        state.requiresDecision = false
        state.liveRejectionEditable = false
        if state.rejected {
            state.prepared = nil
            state.rejected = false
        }
        refreshAvailability()
        if session.snapshot.isSuspended { _ = await session.reconcile() }
        return await session.settleEditing()
    }
    func discardDraft() async -> HistorySubmissionResult {
        guard !unknown, !closing, unboundJournals.isEmpty,
            fields.values.allSatisfy({ $0.compatible && ($0.prepared == nil || $0.rejected) })
        else { return .unexecuted(failure(.unresolved, suspended: true)) }
        guard session.status.phase == .ready || session.status.phase == .blocked,
            let engine = session.engine
        else { return .unexecuted(failure(.busy)) }
        do { try engine.transaction.requireIdle() } catch {
            return .unexecuted(HistorySession.describe(error, stage: .admission))
        }
        defer { session.refreshStatus() }
        do {
            return try await engine.transaction.withReconciliation {
                session.refreshStatus()
                return await engine.transaction.withHostCallback { await discardCurrentFields() }
            }
        } catch { return .unexecuted(HistorySession.describe(error, stage: .admission)) }
    }
    private func discardCurrentFields() async -> HistorySubmissionResult {
        do {
            for state in fields.values where state.requiresDecision || state.proposed != state.base.value {
                try await refresh(state)
            }
            if let transaction { retire(transaction) }
            issue = nil
            refreshAvailability()
            return .rejected
        } catch {
            block(error)
            return .unexecuted(issue!)
        }
    }
    func reconcilePresentation() async {
        guard !unknown, transaction == nil, unboundJournals.isEmpty,
            fields.values.allSatisfy({ $0.prepared == nil && !$0.requiresDecision })
        else { return }
        do {
            for state in fields.values { try await refresh(state) }
            issue = nil
            refreshAvailability()
        } catch { block(error) }
    }
    func reconcileNativeRegistrations() async throws {
        guard session.status.phase != .busy && session.status.phase != .opening && session.status.phase != .closing
        else { throw failure(.busy) }
        let epoch = registrationEpoch
        if let transaction { try capture(transaction) }
        guard epoch == registrationEpoch else { throw failure(.busy) }
        // Explicit host certification authorizes releasing this preserved callback graph.
        clearCertifiedNativeActions()
        unknown = false
        if issue?.cause == .hostProtocol { issue = nil }
        refreshAvailability()
    }
    var nativeCanUndo: Bool { session.status.canUndo }
    var nativeCanRedo: Bool { session.status.canRedo }
    func requestNativeUndo(_ undo: Bool) {
        session.requestNativeOperation(undo ? .undo : .redo)
    }
}
