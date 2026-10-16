// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

extension HistorySession {
    func open(
        mode: HistoryOpenMode,
        configure: @MainActor () async throws -> HistorySessionSetup
    ) async {
        defer {
            opening = false
            refreshStatus()
            let waiters = openingWaiters
            openingWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        do {
            let callbacks = HistorySessionCallbackContext.active.union([ObjectIdentifier(self)])
            let setup = try await HistorySessionCallbackContext.$active.withValue(callbacks) {
                leaseAcquisitionStarted = true
                try await lease.open(mode)
                return try await configure()
            }
            configuration = setup.configuration
            var registered: [String: AnyHistoryOperation] = [:]
            for operation in setup.operations {
                guard registered[operation.operation] == nil else { throw failure(.identityConflict) }
                registered[operation.operation] = operation
            }
            guard !registered.isEmpty, let collection else { throw failure(.invalidInput) }
            operations = registered
            try collection.register(setup: setup, session: self)
            let owner = try collection.storeOwner(for: setup.configuration, session: self)
            storeOwner = owner
            let store = try await owner.acquire()
            let host = try HistoryHostRegistry(
                registrations: registered.values.map { ($0.operation, $0.host) },
                atomicGroupExecutor: setup.atomicGroupExecutor, atomicOutcomeLookup: setup.atomicOutcomeLookup)
            let engine = try await store.openScope(
                setup.configuration.scope, mode: setup.configuration.scopeMode, host: host)
            self.engine = engine
            engine.transaction.participant = nativeCoordinator
            guard let generation = engine.snapshot.generation else { throw failure(.missingHistory) }
            try nativeCoordinator.inspectJournals(configuration: setup.configuration, generation: generation)
            nativeCoordinator.reopened()
            engine.snapshotDidChange = { [weak self, weak engine] _ in
                guard let self, let engine, self.engine === engine else { return }
                self.refreshStatus()
            }
        } catch { issue = Self.describe(error, stage: .admission) }
    }

    public func close() async {
        if closed { return }
        guard !HistorySessionCallbackContext.active.contains(ObjectIdentifier(self)),
            engine.map({
                !HistoryHostCallbackContext.activeTransactions.contains(ObjectIdentifier($0.transaction))
                    && !HistoryStore.deliveringStores.contains(ObjectIdentifier($0.store))
            }) ?? true
        else { return }
        closeRequested = true
        refreshStatus()
        if opening { await withCheckedContinuation { openingWaiters.append($0) } }
        if closing {
            await withCheckedContinuation { closingWaiters.append($0) }
            return
        }
        closing = true
        defer {
            closing = false
            let waiters = closingWaiters
            closingWaiters.removeAll()
            waiters.forEach { $0.resume() }
            refreshStatus()
        }
        do {
            try await nativeCoordinator.safeguardForClose()
            try await engine?.close()
            if let owner = storeOwner {
                if let collection {
                    try await collection.release(owner, session: self)
                } else if let scope = configuration?.scope {
                    try await owner.release(scope: scope)
                }
            }
            try nativeCoordinator.historyDidClose()
            if leaseAcquisitionStarted {
                let callbacks = HistorySessionCallbackContext.active.union([ObjectIdentifier(self)])
                try await HistorySessionCallbackContext.$active.withValue(callbacks) { try await lease.close() }
                leaseAcquisitionStarted = false
            }
            try await nativeCoordinator.safeguardForClose()
            engine = nil
            storeOwner = nil
            closed = true
            issue = nil
            epoch = UUID()
        } catch { issue = Self.describe(error, stage: .finalization) }
    }

    func waitForOpening() async {
        guard !HistorySessionCallbackContext.active.contains(ObjectIdentifier(self)) else { return }
        if opening { await withCheckedContinuation { openingWaiters.append($0) } }
    }
}
