// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryEngine {
    func execute(_ request: Request) async -> HistoryResult {
        do {
            guard !(try scopeRecord().bool("suspended")) else {
                return .failure(HistoryFailure(.unresolved, stage: .reconciliation, disposition: .suspended))
            }
            switch request {
            case .command(let command):
                return await execute(command: command, kind: .command, targetGroup: nil)
            case .undo:
                guard let target = try eligibleGroup(for: .undo) else { return .rejected }
                return await executeInverse(target: target, kind: .undo)
            case .redo:
                guard let target = try eligibleGroup(for: .redo) else { return .rejected }
                return await executeInverse(target: target, kind: .redo)
            }
        } catch {
            return .failure(HistoryFailure(.storage, stage: .admission, disposition: .usable))
        }
    }

    func executeInverse(target: NSManagedObject, kind: HistoryDeliveryKind) async -> HistoryResult {
        do {
            let groupID = try target.uuid("key")
            let actions = try fetch("HistoryActionRecord",
                                    predicate: NSPredicate(format: "group == %@", target),
                                    sort: [NSSortDescriptor(key: "ordinal", ascending: kind == .redo)])
            let members = try actions.map { action -> HistoryMember in
                let prefix = kind == .undo ? "undo" : "redo"
                return HistoryMember(id: try action.uuid("memberID"),
                                     payload: try payload(on: action, prefix: prefix))
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
        let key = transactionKey(command.id)
        do {
            if let prior = try fetchOne("HistoryTransactionRecord", key: key) {
                guard prior.data("fingerprint") == command.fingerprint else {
                    return .failure(HistoryFailure(.identityConflict, stage: .admission, disposition: .usable))
                }
                return await reconcile(prior)
            }
            if let failure = admissionFailure(for: command) {
                return .failure(failure)
            }
            let scopeRow = try scopeRecord()
            let generation = try scopeRow.uuid("generationID")
            let sequence = scopeRow.int64("nextSequence")
            let token = HistoryToken(scope: scope, generation: generation,
                                     sequence: sequence, command: command.id)
            let delivery = try prepare(command, kind: kind, targetGroup: targetGroup,
                                       token: token, scopeRow: scopeRow)
            let outcome = await host.deliver(delivery)
            return await finish(transactionKey: key, outcome: outcome)
        } catch {
            context.rollback()
            let durableStage = (try? fetchOne("HistoryTransactionRecord", key: key))?.string("stage")
            if durableStage == "prepared" {
                do {
                    let prepared = try fetchOne("HistoryTransactionRecord", key: key)
                    prepared?.setValue("cancelled", forKey: "stage")
                    try context.save()
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

    private func admissionFailure(for command: HistoryCommand) -> HistoryFailure? {
        guard command.members.count <= limits.maxMembers,
              command.members.allSatisfy({ $0.payload.data.count <= limits.maxPayloadBytes }),
              command.members.reduce(0, { $0 + $1.payload.data.count }) <= limits.maxPayloadBytes else {
            return HistoryFailure(.capacity, stage: .admission, disposition: .usable)
        }
        guard valid(command) else {
            return HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        guard hasCapacity(for: command) else {
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
        let key = transactionKey(command.id)
        let sequence = token.sequence
        let transaction = insert("HistoryTransactionRecord")
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
        for (ordinal, member) in command.members.enumerated() {
            let row = insert("HistoryMemberRecord")
            row.setValue("\(key):\(ordinal)", forKey: "key")
            row.setValue(Int64(ordinal), forKey: "ordinal")
            row.setValue(member.id.uuidString, forKey: "memberID")
            row.setValue(member.payload.family, forKey: "family")
            row.setValue(Int64(member.payload.version), forKey: "version")
            row.setValue(member.payload.data, forKey: "payload")
            row.setValue(digest(member.payload), forKey: "payloadDigest")
            row.setValue(transaction, forKey: "transaction")
        }
        scopeRow.setValue(sequence + 1, forKey: "nextSequence")
        try context.save()
        transaction.setValue("deliveryStarted", forKey: "stage")
        try context.save()
        return HistoryDelivery(token: token, kind: kind, members: command.members,
                               restorationOrigin: command.restorationOrigin)
    }

    func finish(transactionKey key: String, outcome: HistoryHostOutcome) async -> HistoryResult {
        do {
            guard let transaction = try fetchOne("HistoryTransactionRecord", key: key) else {
                throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
            }
            switch outcome {
            case .unresolved:
                transaction.setValue("unresolved", forKey: "stage")
                try context.save()
                suspend()
                return .failure(HistoryFailure(.unresolved, stage: .reconciliation, disposition: .suspended))
            case .rejected:
                transaction.setValue("rejectionPending", forKey: "stage")
                try context.save()
                return try finalizeRejected(transaction)
            case .accepted(let effects):
                let members = try transactionMembers(transaction)
                guard effects.count == members.count,
                      Set(effects.map(\.memberID)).count == members.count,
                      zip(effects, members).allSatisfy({ $0.memberID.uuidString == $1.string("memberID") }),
                      effects.allSatisfy({ valid($0.undo) && valid($0.redo) }),
                      effects.reduce(0, { $0 + $1.undo.data.count + $1.redo.data.count })
                        <= limits.maxPayloadBytes * 2 else {
                    suspend()
                    return .failure(HistoryFailure(.hostProtocol, stage: .reconciliation, disposition: .suspended))
                }
                for (effect, member) in zip(effects, members) {
                    put(effect.undo, on: member, prefix: "undo")
                    put(effect.redo, on: member, prefix: "redo")
                }
                transaction.setValue("acceptancePending", forKey: "stage")
                try context.save()
                return try finalizeAccepted(transaction)
            }
        } catch {
            context.rollback()
            suspend()
            return .failure(HistoryFailure(.storage, stage: .finalization,
                                           disposition: .suspended, underlyingDescription: String(describing: error)))
        }
    }

    func finalizeAccepted(_ transaction: NSManagedObject) throws -> HistoryResult {
        let kind = HistoryDeliveryKind(rawValue: transaction.string("kind") ?? "") ?? .command
        let group = insert("HistoryGroupRecord")
        let groupKey = transaction.string("groupID") ?? UUID().uuidString
        group.setValue(groupKey, forKey: "key")
        group.setValue(scope.uuidString, forKey: "scopeKey")
        group.setValue(transaction.int64("sequence"), forKey: "sequence")
        group.setValue(kind.rawValue, forKey: "kind")
        group.setValue(kind == .command ? "applied" : "historical", forKey: "state")
        group.setValue(transaction.string("targetGroupID"), forKey: "sourceGroupID")
        if kind == .redo, let original = transaction.string("targetGroupID") {
            let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryGroupRecord")
            request.predicate = NSPredicate(format: "scopeKey == %@ AND kind == %@ AND sourceGroupID == %@",
                                            scope.uuidString, HistoryDeliveryKind.undo.rawValue, original)
            request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: false)]
            request.fetchLimit = 1
            guard let compensation = try context.fetch(request).first else {
                throw HistoryFailure(.hostProtocol, stage: .finalization, disposition: .suspended)
            }
            group.setValue(compensation.string("key"), forKey: "compensationGroupID")
        }
        group.setValue(transaction.string("restorationOrigin"), forKey: "restorationOrigin")
        group.setValue(transaction.int64("memberCount"), forKey: "memberCount")
        group.setValue(transaction.value(forKey: "recordedAt"), forKey: "recordedAt")
        for member in try transactionMembers(transaction) {
            let action = insert("HistoryActionRecord")
            action.setValue(member.string("key"), forKey: "key")
            action.setValue(transaction.string("key"), forKey: "transactionKey")
            action.setValue(member.string("memberID"), forKey: "memberID")
            action.setValue(member.int64("ordinal"), forKey: "ordinal")
            action.setValue(kind.rawValue, forKey: "kind")
            put(try payload(on: member, prefix: "undo"), on: action, prefix: "undo")
            put(try payload(on: member, prefix: "redo"), on: action, prefix: "redo")
            action.setValue(group, forKey: "group")
        }
        switch kind {
        case .command:
            for row in try ordinaryGroups(state: "undone") { row.setValue("branched", forKey: "state") }
        case .undo, .redo:
            if let key = transaction.string("targetGroupID"),
               let target = try fetchOne("HistoryGroupRecord", key: key) {
                target.setValue(kind == .undo ? "undone" : "applied", forKey: "state")
            }
        }
        transaction.setValue("accepted", forKey: "stage")
        try context.save()
        updateSnapshot()
        let token = try token(for: transaction)
        return .accepted(HistoryReceipt(token: token, groupID: try group.uuid("key")))
    }

    func finalizeRejected(_ transaction: NSManagedObject) throws -> HistoryResult {
        let kind = HistoryDeliveryKind(rawValue: transaction.string("kind") ?? "") ?? .command
        if kind != .command, let targetKey = transaction.string("targetGroupID"),
           let target = try fetchOne("HistoryGroupRecord", key: targetKey) {
            target.setValue("invalid", forKey: "state")
        }
        transaction.setValue("rejected", forKey: "stage")
        try context.save()
        updateSnapshot()
        return .rejected
    }
}
