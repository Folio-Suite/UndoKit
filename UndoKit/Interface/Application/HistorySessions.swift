// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Application-owned retention of opening, active, closing and blocked sessions.
@MainActor public final class HistorySessions {
    private struct WorkingScope: Hashable {
        let working: UUID
        let scope: UUID
    }
    private var sessions: [UUID: HistorySession] = [:]
    private var documentOwners: [URL: [ObjectIdentifier: HistorySession]] = [:]
    private var scopes: [WorkingScope: HistorySession] = [:]
    private var stores: [URL: HistorySessionStoreOwner] = [:]
    private var closingAll = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    public var entriesDidChange: (@MainActor () -> Void)?
    public init() {}
    public var entries: [HistorySessionEntry] {
        sessions.values.map {
            HistorySessionEntry(
                documentURL: $0.documentURL, status: $0.status,
                attachmentCount: $0.attachmentCount)
        }.sorted { $0.documentURL.path < $1.documentURL.path }
    }
    public func session(for documentURL: URL) -> HistorySession? {
        let key = canonical(documentURL)
        let matching = Array(documentOwners[key, default: [:]].values)
        return matching.count == 1 ? matching.first : nil
    }
    public func session(scope: UUID, workingIdentity: UUID) -> HistorySession? {
        scopes[WorkingScope(working: workingIdentity, scope: scope)]
    }

    /// Retain before acquisition. Conflicting live ownership is reported as a retained
    /// blocked session; no incoming host replaces another session's registered handler.
    public func open(
        documentURL: URL, mode: HistoryOpenMode, lease: any HistoryHostLease,
        configure: @escaping @MainActor () async throws -> HistorySessionSetup
    ) async -> HistorySession {
        let key = canonical(documentURL)
        guard !closingAll else { return conflict(documentURL: key, lease: lease, cause: .busy) }
        let matching = Array(documentOwners[key, default: [:]].values)
        if let existing = matching.first {
            guard matching.count == 1 else { return conflict(documentURL: key, lease: lease) }
            guard !HistorySessionCallbackContext.active.contains(ObjectIdentifier(existing)) else {
                return conflict(documentURL: key, lease: lease)
            }
            guard existing.lease === lease else { return conflict(documentURL: key, lease: lease) }
            await existing.waitForOpening()
            do {
                let callbacks = HistorySessionCallbackContext.active.union([ObjectIdentifier(existing)])
                let setup = try await HistorySessionCallbackContext.$active.withValue(callbacks) {
                    try await configure()
                }
                guard existing.matches(configuration: setup.configuration, operations: setup.operations, lease: lease)
                else {
                    return conflict(documentURL: key, lease: lease)
                }
            } catch { return conflict(documentURL: key, lease: lease) }
            return existing
        }
        return await create(documentURL: key, mode: mode, lease: lease, configure: configure)
    }

    public func open(
        configuration: HistorySessionConfiguration, lease: any HistoryHostLease,
        operations: [AnyHistoryOperation]
    ) async -> HistorySession {
        guard !closingAll else {
            return conflict(documentURL: canonical(configuration.historyURL), lease: lease, cause: .busy)
        }
        let key = WorkingScope(working: configuration.workingIdentity, scope: configuration.scope)
        if let existing = scopes[key] {
            guard !HistorySessionCallbackContext.active.contains(ObjectIdentifier(existing)) else {
                return conflict(documentURL: canonical(configuration.historyURL), lease: lease)
            }
            guard existing.matches(configuration: configuration, operations: operations, lease: lease) else {
                return conflict(documentURL: canonical(configuration.historyURL), lease: lease)
            }
            await existing.waitForOpening()
            return existing
        }
        // Different scopes may intentionally share the same physical history URL.
        return await create(
            documentURL: canonical(configuration.historyURL), mode: configuration.mode, lease: lease,
            expected: HistorySessionSetup(configuration: configuration, operations: operations)
        ) {
            HistorySessionSetup(configuration: configuration, operations: operations)
        }
    }
    private func create(
        documentURL: URL, mode: HistoryOpenMode, lease: any HistoryHostLease,
        expected: HistorySessionSetup? = nil,
        configure: @escaping @MainActor () async throws -> HistorySessionSetup
    ) async -> HistorySession {
        let session = HistorySession(documentURL: documentURL, lease: lease, collection: self)
        documentOwners[documentURL, default: [:]][ObjectIdentifier(session)] = session
        sessions[UUID()] = session
        changed()
        if let expected {
            session.expect(expected)
            do { try register(setup: expected, session: session) } catch {
                session.refuse(HistorySession.describe(error, stage: .admission))
                return session
            }
        }
        await session.open(mode: mode, configure: configure)
        return session
    }
    private func conflict(
        documentURL: URL, lease: any HistoryHostLease,
        cause: HistoryFailureCause = .identityConflict
    ) -> HistorySession {
        let session = HistorySession(documentURL: documentURL, lease: lease, collection: self)
        sessions[UUID()] = session
        session.refuse(HistoryFailure(cause, stage: .admission, disposition: .usable))
        return session
    }
    public func closeAll() async {
        guard
            !sessions.values.contains(where: { session in
                if HistorySessionCallbackContext.active.contains(ObjectIdentifier(session)) { return true }
                guard let engine = session.engine else { return false }
                return HistoryHostCallbackContext.activeTransactions.contains(ObjectIdentifier(engine.transaction))
                    || HistoryStore.deliveringStores.contains(ObjectIdentifier(engine.store))
            })
        else { return }
        if closingAll {
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        }
        closingAll = true
        defer {
            closingAll = false
            let waiters = closeWaiters
            closeWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        for session in Array(sessions.values) { await session.close() }
    }

    func register(setup: HistorySessionSetup, session: HistorySession) throws {
        let key = WorkingScope(working: setup.configuration.workingIdentity, scope: setup.configuration.scope)
        guard scopes[key] == nil || scopes[key] === session else {
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
        scopes[key] = session
    }
    func storeOwner(
        for configuration: HistorySessionConfiguration,
        session: HistorySession
    ) throws -> HistorySessionStoreOwner {
        let key = canonical(configuration.historyURL)
        if let owner = stores[key] {
            guard owner.configuration.workingIdentity == configuration.workingIdentity,
                owner.configuration.limits == configuration.limits,
                !owner.scopes.contains(configuration.scope)
            else {
                throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
            }
            owner.register(session, scope: configuration.scope)
            return owner
        }
        let owner = HistorySessionStoreOwner(configuration: configuration)
        owner.register(session, scope: configuration.scope)
        stores[key] = owner
        return owner
    }
    func release(_ owner: HistorySessionStoreOwner, session: HistorySession) async throws {
        guard let scope = session.configuration?.scope, owner.scopes.contains(scope) else { return }
        try await owner.release(scope: scope)
        if owner.scopes.isEmpty {
            let key = canonical(owner.configuration.historyURL)
            if stores[key] === owner { stores.removeValue(forKey: key) }
        }
    }
    func changed() {
        for (url, owners) in documentOwners {
            let live = owners.filter { $0.value.status.phase != .closed }
            if live.isEmpty { documentOwners.removeValue(forKey: url) } else { documentOwners[url] = live }
        }
        for (key, session) in scopes where session.status.phase == .closed { scopes.removeValue(forKey: key) }
        for (key, session) in sessions where session.status.phase == .closed && session.attachmentCount == 0 {
            sessions.removeValue(forKey: key)
        }
        entriesDidChange?()
    }
    private func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: false)
    }
}
