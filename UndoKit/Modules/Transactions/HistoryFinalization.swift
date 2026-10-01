// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryTransactionCoordinator {
    func finish(transactionKey key: String, outcome: HistoryHostOutcome) async -> HistoryResult {
        do {
            guard let transaction = try history.fetchOne("HistoryTransactionRecord", key: key) else {
                throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
            }
            switch outcome {
            case .unresolved:
                transaction.setValue("unresolved", forKey: "stage")
                try history.saveContext()
                suspend()
                return .failure(HistoryFailure(.unresolved, stage: .reconciliation, disposition: .suspended))
            case .failure(let failure):
                guard failure.disposition == .usable else {
                    transaction.setValue("unresolved", forKey: "stage")
                    try history.saveContext()
                    suspend()
                    return .failure(failure)
                }
                return try closeUsableFailure(failure, transaction: transaction)
            case .rejected:
                transaction.setValue("rejectionPending", forKey: "stage")
                try history.saveContext()
                return try finalizeRejected(transaction)
            case .accepted(let effects):
                let members = try history.transactionMembers(transaction)
                guard effects.count == members.count,
                      Set(effects.map(\.memberID)).count == members.count,
                      zip(effects, members).allSatisfy({
                          $0.memberID.uuidString == $1.string("memberID")
                      }),
                      effects.allSatisfy({
                          history.valid($0.undo) && history.valid($0.redo) && history.valid($0.resources)
                      }),
                      effects.reduce(0, { $0 + $1.resources.count }) <= 10_000,
                      effects.reduce(0, { total, effect in
                          total + effect.resources.reduce(0) { bytes, reference in
                              bytes + reference.objectKey.utf8.count +
                                  (reference.versionKey?.utf8.count ?? 0) + 64
                          }
                      }) <= limits.maxPayloadBytes,
                      effects.reduce(0, { $0 + $1.undo.data.count + $1.redo.data.count })
                        <= limits.maxPayloadBytes * 2 else {
                    suspend()
                    return .failure(HistoryFailure(.hostProtocol, stage: .reconciliation, disposition: .suspended))
                }
                for (effect, member) in zip(effects, members) {
                    history.put(effect.undo, on: member, prefix: "undo")
                    history.put(effect.redo, on: member, prefix: "redo")
                    try history.addResourceReferences(effect.resources,
                                              ownerType: transaction.bool("recordsAction") ? "action" : "session",
                                              ownerKey: member.string("key") ?? "")
                }
                transaction.setValue("acceptancePending", forKey: "stage")
                try history.saveContext()
                return try transaction.bool("recordsAction")
                    ? finalizeAccepted(transaction) : finalizeSessionAccepted(transaction)
            }
        } catch {
            context.rollback()
            suspend()
            return .failure(HistoryFailure(.storage, stage: .finalization,
                                           disposition: .suspended, underlyingDescription: String(describing: error)))
        }
    }

    func finalizeSessionAccepted(_ transaction: NSManagedObject) throws -> HistoryResult {
        let token = try history.token(for: transaction)
        let groupID = try transaction.uuid("groupID")
        let kind = HistoryDeliveryKind(rawValue: transaction.string("kind") ?? "") ?? .command
        let targetID = transaction.string("targetGroupID").flatMap(UUID.init(uuidString:))
        let effects = try history.transactionMembers(transaction).map { member in
            HistoryEffect(memberID: try member.uuid("memberID"),
                undo: try history.payload(on: member, prefix: "undo"),
                redo: try history.payload(on: member, prefix: "redo"))
        }
        let receipt = history.insert("HistoryRetiredCommandRecord")
        receipt.setValue(transaction.string("key"), forKey: "key")
        receipt.setValue(scope.uuidString, forKey: "scopeKey")
        receipt.setValue(token.generation.uuidString, forKey: "generationID")
        receipt.setValue(token.command.uuidString, forKey: "commandID")
        receipt.setValue(transaction.data("fingerprint"), forKey: "fingerprint")
        receipt.setValue(token.sequence, forKey: "sequence")
        receipt.setValue(groupID.uuidString, forKey: "groupID")
        let gap = history.insert("HistoryGapRecord")
        gap.setValue(UUID().uuidString, forKey: "key")
        gap.setValue(scope.uuidString, forKey: "scopeKey")
        gap.setValue(token.generation.uuidString, forKey: "generationID")
        gap.setValue(token.sequence - 1, forKey: "lowerExclusiveSequence")
        gap.setValue(token.sequence, forKey: "upperInclusiveSequence")
        for member in try history.transactionMembers(transaction) { context.delete(member) }
        context.delete(transaction)
        let scopeRow = try history.scopeRecord()
        if scopeRow.int64("offStartSequence") > 0 &&
           token.sequence >= scopeRow.int64("offStartSequence") &&
           scopeRow.int64("undoFloorSequence") < scopeRow.int64("offStartSequence") {
            scopeRow.setValue(token.sequence, forKey: "undoFloorSequence")
        }
        scopeRow.setValue(scopeRow.int64("committedVersion") + 1, forKey: "committedVersion")
        try history.saveContext()
        guard token.sequence >= sessionStartSequence else {
            updateSnapshot()
            return .accepted(HistoryReceipt(token: token, groupID: groupID))
        }
        switch kind {
        case .command:
            sessionGroups.removeAll(where: { !$0.applied })
            sessionGroups.append(SessionGroup(id: groupID, effects: effects))
            if sessionGroups.count > limits.maxUndoGroups {
                sessionGroups.removeFirst(sessionGroups.count - limits.maxUndoGroups)
            }
        case .undo, .redo:
            if let target = targetID,
               let index = sessionGroups.firstIndex(where: { $0.id == target }) {
                sessionGroups[index].applied = kind == .redo
            } else if let target = targetID {
                // The first Off operation may reverse a previously retained
                // group. Its counterpart remains available in this session,
                // while the durable group itself stays historical across the gap.
                let swapped = effects.map { effect in
                    HistoryEffect(memberID: effect.memberID, undo: effect.redo,
                                  redo: effect.undo, resources: effect.resources)
                }
                sessionGroups.append(SessionGroup(id: target, effects: swapped,
                                                  applied: kind == .redo))
            }
        }
        updateSnapshot()
        return .accepted(HistoryReceipt(token: token, groupID: groupID))
    }

    private func closeUsableFailure(_ failure: HistoryFailure,
                                    transaction: NSManagedObject) throws -> HistoryResult {
        // A usable failure proves no effect, but does not authoritatively
        // reject the target's semantic Undo/Redo eligibility.
        let recorded = HistoryFailure(
            failure.cause, stage: failure.stage, disposition: .usable,
            underlyingDescription: failure.underlyingDescription.map { String($0.prefix(1_024)) }
        )
        transaction.setValue(recorded.cause.rawValue, forKey: "failureCause")
        transaction.setValue(recorded.stage.rawValue, forKey: "failureStage")
        transaction.setValue(recorded.underlyingDescription, forKey: "failureDescription")
        transaction.setValue("cancelled", forKey: "stage")
        try history.saveContext()
        updateSnapshot()
        return .failure(recorded)
    }

    func finalizeAccepted(_ transaction: NSManagedObject) throws -> HistoryResult {
        let kind = HistoryDeliveryKind(rawValue: transaction.string("kind") ?? "") ?? .command
        let group = history.insert("HistoryGroupRecord")
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
        if transaction.string("presentationFamily") != nil {
            group.setValue(transaction.string("presentationFamily"), forKey: "presentationFamily")
            group.setValue(transaction.value(forKey: "presentationVersion"), forKey: "presentationVersion")
            group.setValue(transaction.value(forKey: "presentationPayload"), forKey: "presentationPayload")
            group.setValue(transaction.value(forKey: "presentationDigest"), forKey: "presentationDigest")
        }
        let finalizedMembers = try history.transactionMembers(transaction)
        for member in finalizedMembers {
            let action = history.insert("HistoryActionRecord")
            action.setValue(member.string("key"), forKey: "key")
            action.setValue(transaction.string("key"), forKey: "transactionKey")
            action.setValue(member.string("memberID"), forKey: "memberID")
            action.setValue(member.int64("ordinal"), forKey: "ordinal")
            action.setValue(kind.rawValue, forKey: "kind")
            history.put(try history.payload(on: member, prefix: "undo"), on: action, prefix: "undo")
            history.put(try history.payload(on: member, prefix: "redo"), on: action, prefix: "redo")
            action.setValue(group, forKey: "group")
        }
        // Action payloads are the accepted historical material. The prepared
        // delivery members are terminal duplicates and no longer aid recovery.
        for member in finalizedMembers { context.delete(member) }
        switch kind {
        case .command:
            for row in try history.ordinaryGroups(state: "undone") { row.setValue("branched", forKey: "state") }
        case .undo, .redo:
            if let key = transaction.string("targetGroupID"),
               let target = try history.groupRecord(key: key) {
                target.setValue(kind == .undo ? "undone" : "applied", forKey: "state")
            }
        }
        transaction.setValue("accepted", forKey: "stage")
        transaction.setValue(nil, forKey: "presentationPayload")
        transaction.setValue(nil, forKey: "presentationDigest")
        let scopeRow = try history.scopeRecord()
        group.setValue(scopeRow.int64("latestAcceptedSequence"), forKey: "previousAcceptedSequence")
        scopeRow.setValue(transaction.int64("sequence"), forKey: "latestAcceptedSequence")
        scopeRow.setValue(scopeRow.int64("committedVersion") + 1, forKey: "committedVersion")
        try history.saveContext()
        updateSnapshot()
        let token = try history.token(for: transaction)
        return .accepted(HistoryReceipt(token: token, groupID: try group.uuid("key")))
    }

    func finalizeRejected(_ transaction: NSManagedObject) throws -> HistoryResult {
        let kind = HistoryDeliveryKind(rawValue: transaction.string("kind") ?? "") ?? .command
        if kind != .command, let targetKey = transaction.string("targetGroupID"),
           let target = try history.groupRecord(key: targetKey) {
            target.setValue("invalid", forKey: "state")
        }
        transaction.setValue("rejected", forKey: "stage")
        for member in try history.fetch("HistoryMemberRecord", predicate: NSPredicate(
            format: "transaction == %@", transaction)) { context.delete(member) }
        transaction.setValue(nil, forKey: "presentationPayload")
        transaction.setValue(nil, forKey: "presentationDigest")
        try history.saveContext()
        updateSnapshot()
        return .rejected
    }
}
