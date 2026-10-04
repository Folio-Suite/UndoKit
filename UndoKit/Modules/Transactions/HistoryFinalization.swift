// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryTransactionCoordinator {
    func finish(transactionKey key: String, outcome: HistoryHostOutcome) async -> HistoryResult {
        do {
            guard let transaction = try history.fetchOne(HistoryTransactionRecord.self, keyPath: \.key, key: key) else {
                throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
            }
            switch outcome {
            case .unresolved:
                transaction.stage = "unresolved"
                try history.saveContext()
                suspend()
                return .failure(HistoryFailure(.unresolved, stage: .reconciliation, disposition: .suspended))
            case .failure(let failure):
                guard failure.disposition == .usable else {
                    transaction.stage = "unresolved"
                    try history.saveContext()
                    suspend()
                    return .failure(failure)
                }
                return try closeUsableFailure(failure, transaction: transaction)
            case .rejected:
                transaction.stage = "rejectionPending"
                try history.saveContext()
                return try finalizeRejected(transaction)
            case .accepted(let effects):
                let members = try history.transactionMembers(transaction)
                guard effects.count == members.count,
                      Set(effects.map(\.memberID)).count == members.count,
                      zip(effects, members).allSatisfy({
                          $0.memberID.uuidString == $1.memberID
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
                    history.put(effect.undo, on: member, role: .undo)
                    history.put(effect.redo, on: member, role: .redo)
                    try history.addResourceReferences(effect.resources,
                                              ownerType: transaction.recordsAction ? "action" : "session",
                                              ownerKey: member.key ?? "")
                }
                transaction.stage = "acceptancePending"
                try history.saveContext()
                return try transaction.recordsAction
                    ? finalizeAccepted(transaction) : finalizeSessionAccepted(transaction)
            }
        } catch {
            context.rollback()
            suspend()
            return .failure(HistoryFailure(.storage, stage: .finalization,
                                           disposition: .suspended, underlyingDescription: String(describing: error)))
        }
    }

    func finalizeSessionAccepted(_ transaction: HistoryTransactionRecord) throws -> HistoryResult {
        let token = try history.token(for: transaction)
        let groupID = try transaction.uuid(transaction.groupID)
        let kind = HistoryDeliveryKind(rawValue: transaction.kind ?? "") ?? .command
        let targetID = transaction.targetGroupID.flatMap(UUID.init(uuidString:))
        let effects = try history.transactionMembers(transaction).map { member in
            HistoryEffect(memberID: try member.uuid(member.memberID),
                undo: try history.payload(on: member, role: .undo),
                redo: try history.payload(on: member, role: .redo))
        }
        let receipt = history.insert(HistoryRetiredCommandRecord.self)
        receipt.key = transaction.key
        receipt.scopeKey = scope.uuidString
        receipt.generationID = token.generation.uuidString
        receipt.commandID = token.command.uuidString
        receipt.fingerprint = transaction.fingerprint
        receipt.sequence = token.sequence
        receipt.groupID = groupID.uuidString
        let gap = history.insert(HistoryGapRecord.self)
        gap.key = UUID().uuidString
        gap.scopeKey = scope.uuidString
        gap.generationID = token.generation.uuidString
        gap.lowerExclusiveSequence = token.sequence - 1
        gap.upperInclusiveSequence = token.sequence
        for member in try history.transactionMembers(transaction) { context.delete(member) }
        context.delete(transaction)
        let scopeRow = try history.scopeRecord()
        if scopeRow.offStartSequence > 0 &&
           token.sequence >= scopeRow.offStartSequence &&
           scopeRow.undoFloorSequence < scopeRow.offStartSequence {
            scopeRow.undoFloorSequence = token.sequence
        }
        scopeRow.committedVersion += 1
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
                                    transaction: HistoryTransactionRecord) throws -> HistoryResult {
        // A usable failure proves no effect, but does not authoritatively
        // reject the target's semantic Undo/Redo eligibility.
        let recorded = HistoryFailure(
            failure.cause, stage: failure.stage, disposition: .usable,
            underlyingDescription: failure.underlyingDescription.map { String($0.prefix(1_024)) }
        )
        transaction.failureCause = recorded.cause.rawValue
        transaction.failureStage = recorded.stage.rawValue
        transaction.failureDescription = recorded.underlyingDescription
        transaction.stage = "cancelled"
        try history.saveContext()
        updateSnapshot()
        return .failure(recorded)
    }

    func finalizeAccepted(_ transaction: HistoryTransactionRecord) throws -> HistoryResult {
        let kind = HistoryDeliveryKind(rawValue: transaction.kind ?? "") ?? .command
        let group = history.insert(HistoryGroupRecord.self)
        let groupKey = transaction.groupID ?? UUID().uuidString
        group.key = groupKey
        group.scopeKey = scope.uuidString
        group.sequence = transaction.sequence
        group.kind = kind.rawValue
        group.state = kind == .command ? "applied" : "historical"
        group.sourceGroupID = transaction.targetGroupID
        if kind == .redo, let original = transaction.targetGroupID {
            let request = HistoryGroupRecord.fetchRequest()
            request.predicate = NSPredicate(format: "\(#keyPath(HistoryGroupRecord.scopeKey)) == %@ AND " +
                "\(#keyPath(HistoryGroupRecord.kind)) == %@ AND " +
                "\(#keyPath(HistoryGroupRecord.sourceGroupID)) == %@",
                                            scope.uuidString, HistoryDeliveryKind.undo.rawValue, original)
            request.sortDescriptors = [NSSortDescriptor(key: #keyPath(HistoryGroupRecord.sequence), ascending: false)]
            request.fetchLimit = 1
            guard let compensation = try context.fetch(request).first else {
                throw HistoryFailure(.hostProtocol, stage: .finalization, disposition: .suspended)
            }
            group.compensationGroupID = compensation.key
        }
        group.restorationOrigin = transaction.restorationOrigin
        group.memberCount = transaction.memberCount
        group.recordedAt = transaction.recordedAt
        if transaction.presentationFamily != nil {
            group.presentationFamily = transaction.presentationFamily
            group.presentationVersion = transaction.presentationVersion
            group.presentationPayload = transaction.presentationPayload
            group.presentationDigest = transaction.presentationDigest
        }
        let finalizedMembers = try history.transactionMembers(transaction)
        for member in finalizedMembers {
            let action = history.insert(HistoryActionRecord.self)
            action.key = member.key
            action.transactionKey = transaction.key
            action.memberID = member.memberID
            action.ordinal = member.ordinal
            action.kind = kind.rawValue
            history.put(try history.payload(on: member, role: .undo), on: action, role: .undo)
            history.put(try history.payload(on: member, role: .redo), on: action, role: .redo)
            action.group = group
        }
        // Action payloads are the accepted historical material. The prepared
        // delivery members are terminal duplicates and no longer aid recovery.
        for member in finalizedMembers { context.delete(member) }
        switch kind {
        case .command:
            for row in try history.ordinaryGroups(state: "undone") { row.state = "branched" }
        case .undo, .redo:
            if let key = transaction.targetGroupID,
               let target = try history.groupRecord(key: key) {
                target.state = kind == .undo ? "undone" : "applied"
            }
        }
        transaction.stage = "accepted"
        transaction.presentationPayload = nil
        transaction.presentationDigest = nil
        let scopeRow = try history.scopeRecord()
        group.previousAcceptedSequence = scopeRow.latestAcceptedSequence
        scopeRow.latestAcceptedSequence = transaction.sequence
        scopeRow.committedVersion += 1
        try history.saveContext()
        updateSnapshot()
        let token = try history.token(for: transaction)
        return .accepted(HistoryReceipt(token: token, groupID: try group.uuid(group.key)))
    }

    func finalizeRejected(_ transaction: HistoryTransactionRecord) throws -> HistoryResult {
        let kind = HistoryDeliveryKind(rawValue: transaction.kind ?? "") ?? .command
        if kind != .command, let targetKey = transaction.targetGroupID,
           let target = try history.groupRecord(key: targetKey) {
            target.state = "invalid"
        }
        transaction.stage = "rejected"
        for member in try history.fetch(HistoryMemberRecord.self, predicate: NSPredicate(
            format: "\(#keyPath(HistoryMemberRecord.transaction)) == %@", transaction)) { context.delete(member) }
        transaction.presentationPayload = nil
        transaction.presentationDigest = nil
        try history.saveContext()
        updateSnapshot()
        return .rejected
    }
}
