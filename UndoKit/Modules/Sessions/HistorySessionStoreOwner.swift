// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Retained before asynchronous store acquisition, including failed partial session setup.
@MainActor final class HistorySessionStoreOwner {
    let configuration: HistorySessionConfiguration
    var scopes: Set<UUID> = []
    private struct WeakSession { weak var value: HistorySession? }
    private var sessions: [UUID: WeakSession] = [:]
    private(set) var store: HistoryStore?
    private var acquisition: Task<HistoryStore, Error>?
    init(configuration: HistorySessionConfiguration) { self.configuration = configuration }
    func register(_ session: HistorySession, scope: UUID) {
        scopes.insert(scope)
        sessions[scope] = WeakSession(value: session)
    }
    func requireNativeIdle() throws {
        for session in sessions.values.compactMap(\.value) {
            guard session.status.phase == .ready, !session.status.requiresDraftDecision,
                try session.nativeCoordinator.capturePrerequisite() == nil
            else {
                throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
            }
        }
    }
    func release(scope: UUID) async throws {
        guard scopes.contains(scope) else { return }
        if scopes.count == 1 { try await store?.close() }
        scopes.remove(scope)
        sessions.removeValue(forKey: scope)
    }
    func acquire() async throws -> HistoryStore {
        if let store { return store }
        let task: Task<HistoryStore, Error>
        if let acquisition {
            task = acquisition
        } else {
            let configuration = configuration
            task = Task { @MainActor in
                try await HistoryStore.open(
                    at: configuration.historyURL,
                    workingIdentity: configuration.workingIdentity, mode: configuration.mode,
                    limits: configuration.limits)
            }
            acquisition = task
        }
        let acquired = try await task.value
        store = acquired
        return acquired
    }
}
