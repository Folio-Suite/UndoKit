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
            guard !scopeRow.bool("suspended") else {
                return .failure(HistoryFailure(.unresolved, stage: .reconciliation, disposition: .suspended))
            }
            let boundGeneration: UUID?
            switch request {
            case .command(let command): boundGeneration = command.expectedGeneration
            case .undo(let generation), .redo(let generation): boundGeneration = generation
            }
            if try scopeRow.bool("requiresGenerationBinding") &&
               boundGeneration != scopeRow.uuid("generationID") {
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

    func executeInverse(target: NSManagedObject, kind: HistoryDeliveryKind) async -> HistoryResult {
        do {
            let groupID = try target.uuid("key")
            let actions = try history.fetch("HistoryActionRecord",
                                    predicate: NSPredicate(format: "group == %@", target),
                                    sort: [NSSortDescriptor(key: "ordinal", ascending: kind == .redo)])
            let members = try actions.map { action -> HistoryMember in
                let prefix = kind == .undo ? "undo" : "redo"
                return HistoryMember(id: try action.uuid("memberID"),
                                     payload: try history.payload(on: action, prefix: prefix))
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
            if let prior = try history.fetchOne("HistoryTransactionRecord", key: key) {
                guard prior.data("fingerprint") == command.fingerprint else {
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
            if !scopeRow.bool("recordingEnabled") &&
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
            let generation = try scopeRow.uuid("generationID")
            let sequence = scopeRow.int64("nextSequence")
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
            let durableStage = (try? history.fetchOne("HistoryTransactionRecord", key: key))?.string("stage")
            if store.writeFailed {
                let stage: HistoryFailureStage = durableStage == nil ? .preparation : .finalization
                return .failure(HistoryFailure(.storage, stage: stage, disposition: .suspended,
                                               underlyingDescription: String(describing: error)))
            }
            if durableStage == "prepared" {
                do {
                    let prepared = try history.fetchOne("HistoryTransactionRecord", key: key)
                    prepared?.setValue("cancelled", forKey: "stage")
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
        scopeRow: NSManagedObject
    ) throws -> HistoryDelivery {
        let key = history.transactionKey(command.id)
        let sequence = token.sequence
        let transaction = history.insert("HistoryTransactionRecord")
        transaction.setValue(key, forKey: "key")
        transaction.setValue(scope.uuidString, forKey: "scopeKey")
        transaction.setValue(command.id.uuidString, forKey: "commandID")
        transaction.setValue(command.fingerprint, forKey: "fingerprint")
        transaction.setValue(token.generation.uuidString, forKey: "generationID")
        transaction.setValue(sequence, forKey: "sequence")
        transaction.setValue("prepared", forKey: "stage")
        transaction.setValue(kind.rawValue, forKey: "kind")
        transaction.setValue(command.id.uuidString, forKey: "groupID")
        transaction.setValue(targetGroup?.uuidString, forKey: "targetGroupID")
        transaction.setValue(command.restorationOrigin?.uuidString, forKey: "restorationOrigin")
        transaction.setValue(Int64(command.members.count), forKey: "memberCount")
        transaction.setValue(Date(), forKey: "recordedAt")
        transaction.setValue(scopeRow.bool("recordingEnabled"), forKey: "recordsAction")
        if let presentation = command.presentation {
            history.put(presentation, on: transaction, prefix: "presentation")
        }
        for (ordinal, member) in command.members.enumerated() {
            let row = history.insert("HistoryMemberRecord")
            row.setValue("\(key):\(ordinal)", forKey: "key")
            row.setValue(Int64(ordinal), forKey: "ordinal")
            row.setValue(member.id.uuidString, forKey: "memberID")
            row.setValue(member.payload.family, forKey: "family")
            row.setValue(Int64(member.payload.version), forKey: "version")
            row.setValue(member.payload.data, forKey: "payload")
            row.setValue(history.digest(member.payload), forKey: "payloadDigest")
            row.setValue(transaction, forKey: "transaction")
        }
        scopeRow.setValue(sequence + 1, forKey: "nextSequence")
        try history.saveContext()
        transaction.setValue("deliveryStarted", forKey: "stage")
        try history.saveContext()
        return HistoryDelivery(token: token, kind: kind, members: command.members,
                               restorationOrigin: command.restorationOrigin)
    }

}
