// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryTransactionCoordinator {
    func execute(_ request: Request) async -> HistoryResult {
        do {
            guard !store.writeFailed else {
                return .failure(HistoryFailure(.storage, stage: .admission, disposition: .suspended))
            }
            let scopeRow = try history.scopeRecord()
            guard !scopeRow.suspended else {
                return .failure(HistoryFailure(.unresolved, stage: .reconciliation, disposition: .suspended))
            }
            let boundGeneration: UUID?
            switch request {
            case .command(let command): boundGeneration = command.expectedGeneration
            case .undo(let generation), .redo(let generation): boundGeneration = generation
            }
            if try scopeRow.requiresGenerationBinding &&
               boundGeneration != scopeRow.uuid(scopeRow.generationID) {
                return .failure(HistoryFailure(.identityConflict, stage: .admission, disposition: .usable))
            }
            switch request {
            case .command(let command):
                return await execute(command: command, kind: .command, targetGroup: nil)
            case .undo:
                if let group = sessionGroups.last(where: { $0.applied }) {
                    return await executeSessionInverse(group, kind: .undo)
                }
                guard let target = try history.eligibleGroup(for: .undo) else { return .rejected }
                return await executeInverse(target: target, kind: .undo)
            case .redo:
                if let group = sessionGroups.first(where: { !$0.applied }) {
                    return await executeSessionInverse(group, kind: .redo)
                }
                guard let target = try history.eligibleGroup(for: .redo) else { return .rejected }
                return await executeInverse(target: target, kind: .redo)
            }
        } catch let failure as HistoryFailure where failure.cause == .identityConflict {
            return .failure(failure)
        } catch {
            return .failure(HistoryFailure(.storage, stage: .admission, disposition: .usable))
        }
    }

    private func executeSessionInverse(_ group: SessionGroup,
                                       kind: HistoryDeliveryKind) async -> HistoryResult {
        let effects: [HistoryEffect] = kind == .undo ? Array(group.effects.reversed()) : group.effects
        let commandID = UUID()
        let members = effects.map { effect in
            HistoryMember(id: effect.memberID,
                          payload: kind == .undo ? effect.undo : effect.redo)
        }
        let command = HistoryCommand(id: commandID,
            fingerprint: Data("\(kind.rawValue):\(group.id.uuidString):\(commandID.uuidString)".utf8),
            members: members)
        return await execute(command: command, kind: kind, targetGroup: group.id)
    }

    func executeInverse(target: HistoryGroupRecord, kind: HistoryDeliveryKind) async -> HistoryResult {
        do {
            let groupID = try target.uuid(target.key)
            let actions = try history.fetch(HistoryActionRecord.self,
                                    predicate: NSPredicate(format: "\(#keyPath(HistoryActionRecord.group)) == %@", target),
                                    sort: [NSSortDescriptor(key: #keyPath(HistoryActionRecord.ordinal), ascending: kind == .redo)])
            let members = try actions.map { action -> HistoryMember in
                let role: HistoryScopeStorage.CompensationPayloadRole = kind == .undo ? .undo : .redo
                return HistoryMember(id: try action.uuid(action.memberID),
                                     payload: try history.payload(on: action, role: role))
            }
            let commandID = UUID()
            let fingerprint = Data("\(kind.rawValue):\(groupID.uuidString):\(commandID.uuidString)".utf8)
            let command = HistoryCommand(id: commandID, fingerprint: fingerprint, members: members)
            return await execute(command: command, kind: kind, targetGroup: groupID)
        } catch {
            return .failure(HistoryFailure(.storage, stage: .admission, disposition: .usable))
        }
    }

    func execute(command: HistoryCommand, kind: HistoryDeliveryKind,
                 targetGroup: UUID?) async -> HistoryResult {
        let key = history.transactionKey(command.id)
        do {
            if let prior = try history.fetchOne(HistoryTransactionRecord.self, keyPath: \.key, key: key) {
                guard prior.fingerprint == command.fingerprint else {
                    return .failure(HistoryFailure(.identityConflict, stage: .admission, disposition: .usable))
                }
                return await reconcile(prior)
            }
            if let receipt = try history.retiredCommandReceipt(key: key, fingerprint: command.fingerprint) {
                return .accepted(receipt)
            }
            if let failure = admissionFailure(for: command) {
                return .failure(failure)
            }
            let scopeRow = try history.scopeRecord()
            if !scopeRow.recordingEnabled &&
               (kind == .command || sessionGroups.first(where: { $0.id == targetGroup }) == nil) {
                // Reserve the largest bounded inverse pair before delivery: a
                // host effect may be larger than its submitted opaque intent.
                let budget = min(limits.maxStoreBytes / 4,
                                 Int64(limits.maxPayloadBytes) * Int64(limits.maxUndoGroups))
                let reserve = Int64(limits.maxPayloadBytes) * 2
                guard reserve <= budget - sessionEffectBytes else {
                    return .failure(HistoryFailure(.capacity, stage: .admission, disposition: .usable))
                }
            }
            let generation = try scopeRow.uuid(scopeRow.generationID)
            let sequence = scopeRow.nextSequence
            let token = HistoryToken(scope: scope, generation: generation,
                                     sequence: sequence, command: command.id)
            let delivery = try prepare(command, kind: kind, targetGroup: targetGroup,
                                       token: token, scopeRow: scopeRow)
            let activeStores = HistoryStore.deliveringStores.union([ObjectIdentifier(store)])
            let outcome = await HistoryStore.$deliveringStores.withValue(activeStores) {
                await deliverToHost(delivery)
            }
            return await finish(transactionKey: key, outcome: outcome)
        } catch let failure as HistoryFailure where failure.cause == .identityConflict {
            return .failure(failure)
        } catch {
            context.rollback()
            let durableStage = (try? history.fetchOne(HistoryTransactionRecord.self, keyPath: \.key, key: key))?.stage
            if store.writeFailed {
                let stage: HistoryFailureStage = durableStage == nil ? .preparation : .finalization
                return .failure(HistoryFailure(.storage, stage: stage, disposition: .suspended,
                                               underlyingDescription: String(describing: error)))
            }
            if durableStage == "prepared" {
                do {
                    let prepared = try history.fetchOne(HistoryTransactionRecord.self, keyPath: \.key, key: key)
                    prepared?.stage = "cancelled"
                    try history.saveContext()
                    return .failure(HistoryFailure(.storage, stage: .preparation,
                                                   disposition: .usable,
                                                   underlyingDescription: String(describing: error)))
                } catch {
                    context.rollback()
                    suspend()
                    return .failure(HistoryFailure(.storage, stage: .preparation,
                                                   disposition: .suspended,
                                                   underlyingDescription: String(describing: error)))
                }
            }
            if durableStage == "deliveryStarted" || durableStage == "acceptancePending" {
                suspend()
                return .failure(HistoryFailure(.storage, stage: .finalization,
                    disposition: .suspended, underlyingDescription: String(describing: error)
                ))
            }
            return .failure(HistoryFailure(.storage, stage: .preparation,
                                           disposition: .usable, underlyingDescription: String(describing: error)))
        }
    }

    private func deliverToHost(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        let activeTransactions = HistoryHostCallbackContext.activeTransactions.union([ObjectIdentifier(self)])
        return await HistoryHostCallbackContext.$activeTransactions.withValue(activeTransactions) {
            await host.deliver(delivery)
        }
    }

    private func admissionFailure(for command: HistoryCommand) -> HistoryFailure? {
        guard command.members.count <= limits.maxMembers,
              command.members.allSatisfy({ $0.payload.data.count <= limits.maxPayloadBytes }),
              command.members.reduce(0, { $0 + $1.payload.data.count }) <= limits.maxPayloadBytes else {
            return HistoryFailure(.capacity, stage: .admission, disposition: .usable)
        }
        guard history.valid(command) else {
            return HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        guard history.hasCapacity(for: command) else {
            return HistoryFailure(.capacity, stage: .admission, disposition: .usable)
        }
        return nil
    }

    private func prepare(
        _ command: HistoryCommand,
        kind: HistoryDeliveryKind,
        targetGroup: UUID?,
        token: HistoryToken,
        scopeRow: HistoryScopeRecord
    ) throws -> HistoryDelivery {
        let key = history.transactionKey(command.id)
        let sequence = token.sequence
        let transaction = history.insert(HistoryTransactionRecord.self)
        transaction.key = key
        transaction.scopeKey = scope.uuidString
        transaction.commandID = command.id.uuidString
        transaction.fingerprint = command.fingerprint
        transaction.generationID = token.generation.uuidString
        transaction.sequence = sequence
        transaction.stage = "prepared"
        transaction.kind = kind.rawValue
        transaction.groupID = command.id.uuidString
        transaction.targetGroupID = targetGroup?.uuidString
        transaction.restorationOrigin = command.restorationOrigin?.uuidString
        transaction.memberCount = Int64(command.members.count)
        transaction.recordedAt = Date()
        transaction.recordsAction = scopeRow.recordingEnabled
        if let presentation = command.presentation {
            history.putPresentation(presentation, on: transaction)
        }
        for (ordinal, member) in command.members.enumerated() {
            let row = history.insert(HistoryMemberRecord.self)
            row.key = "\(key):\(ordinal)"
            row.ordinal = Int64(ordinal)
            row.memberID = member.id.uuidString
            row.family = member.payload.family
            row.version = Int64(member.payload.version)
            row.payload = member.payload.data
            row.payloadDigest = history.digest(member.payload)
            row.transaction = transaction
        }
        scopeRow.nextSequence = sequence + 1
        try history.saveContext()
        transaction.stage = "deliveryStarted"
        try history.saveContext()
        return HistoryDelivery(token: token, kind: kind, members: command.members,
                               restorationOrigin: command.restorationOrigin)
    }

}
