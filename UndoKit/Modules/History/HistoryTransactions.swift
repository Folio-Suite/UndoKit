// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryEngine {
    func execute(_ request: Request) async -> HistoryResult {
        do {
            guard !store.writeFailed else {
                return .failure(HistoryFailure(.storage, stage: .admission, disposition: .suspended))
            }
            let scopeRow = try scopeRecord()
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
                guard let target = try eligibleGroup(for: .undo) else { return .rejected }
                return await executeInverse(target: target, kind: .undo)
            case .redo:
                if let group = sessionGroups.first(where: { !$0.applied }) {
                    return await executeSessionInverse(group, kind: .redo)
                }
                guard let target = try eligibleGroup(for: .redo) else { return .rejected }
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
            if let receipt = try retiredCommandReceipt(key: key, fingerprint: command.fingerprint) {
                return .accepted(receipt)
            }
            if let failure = admissionFailure(for: command) {
                return .failure(failure)
            }
            let scopeRow = try scopeRecord()
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
            let durableStage = (try? fetchOne("HistoryTransactionRecord", key: key))?.string("stage")
            if store.writeFailed {
                let stage: HistoryFailureStage = durableStage == nil ? .preparation : .finalization
                return .failure(HistoryFailure(.storage, stage: stage, disposition: .suspended,
                                               underlyingDescription: String(describing: error)))
            }
            if durableStage == "prepared" {
                do {
                    let prepared = try fetchOne("HistoryTransactionRecord", key: key)
                    prepared?.setValue("cancelled", forKey: "stage")
                    try saveContext()
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
        let activeEngines = HistoryHostCallbackContext.activeEngines.union([ObjectIdentifier(self)])
        return await HistoryHostCallbackContext.$activeEngines.withValue(activeEngines) {
            await host.deliver(delivery)
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
        transaction.setValue(scopeRow.bool("recordingEnabled"), forKey: "recordsAction")
        if let presentation = command.presentation {
            put(presentation, on: transaction, prefix: "presentation")
        }
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
        try saveContext()
        transaction.setValue("deliveryStarted", forKey: "stage")
        try saveContext()
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
                try saveContext()
                suspend()
                return .failure(HistoryFailure(.unresolved, stage: .reconciliation, disposition: .suspended))
            case .failure(let failure):
                guard failure.disposition == .usable else {
                    transaction.setValue("unresolved", forKey: "stage")
                    try saveContext()
                    suspend()
                    return .failure(failure)
                }
                return try closeUsableFailure(failure, transaction: transaction)
            case .rejected:
                transaction.setValue("rejectionPending", forKey: "stage")
                try saveContext()
                return try finalizeRejected(transaction)
            case .accepted(let effects):
                let members = try transactionMembers(transaction)
                guard effects.count == members.count,
                      Set(effects.map(\.memberID)).count == members.count,
                      zip(effects, members).allSatisfy({ $0.memberID.uuidString == $1.string("memberID") }),
                      effects.allSatisfy({ valid($0.undo) && valid($0.redo) && valid($0.resources) }),
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
                    put(effect.undo, on: member, prefix: "undo")
                    put(effect.redo, on: member, prefix: "redo")
                    try addResourceReferences(effect.resources,
                                              ownerType: transaction.bool("recordsAction") ? "action" : "session",
                                              ownerKey: member.string("key") ?? "")
                }
                transaction.setValue("acceptancePending", forKey: "stage")
                try saveContext()
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
        let token = try token(for: transaction)
        let groupID = try transaction.uuid("groupID")
        let kind = HistoryDeliveryKind(rawValue: transaction.string("kind") ?? "") ?? .command
        let targetID = transaction.string("targetGroupID").flatMap(UUID.init(uuidString:))
        let effects = try transactionMembers(transaction).map { member in
            HistoryEffect(memberID: try member.uuid("memberID"),
                undo: try payload(on: member, prefix: "undo"),
                redo: try payload(on: member, prefix: "redo"))
        }
        let receipt = insert("HistoryRetiredCommandRecord")
        receipt.setValue(transaction.string("key"), forKey: "key")
        receipt.setValue(scope.uuidString, forKey: "scopeKey")
        receipt.setValue(token.generation.uuidString, forKey: "generationID")
        receipt.setValue(token.command.uuidString, forKey: "commandID")
        receipt.setValue(transaction.data("fingerprint"), forKey: "fingerprint")
        receipt.setValue(token.sequence, forKey: "sequence")
        receipt.setValue(groupID.uuidString, forKey: "groupID")
        let gap = insert("HistoryGapRecord")
        gap.setValue(UUID().uuidString, forKey: "key")
        gap.setValue(scope.uuidString, forKey: "scopeKey")
        gap.setValue(token.generation.uuidString, forKey: "generationID")
        gap.setValue(token.sequence - 1, forKey: "lowerExclusiveSequence")
        gap.setValue(token.sequence, forKey: "upperInclusiveSequence")
        for member in try transactionMembers(transaction) { context.delete(member) }
        context.delete(transaction)
        let scopeRow = try scopeRecord()
        if scopeRow.int64("undoFloorSequence") == 0 {
            scopeRow.setValue(token.sequence, forKey: "undoFloorSequence")
        }
        scopeRow.setValue(scopeRow.int64("committedVersion") + 1, forKey: "committedVersion")
        try saveContext()
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
        try saveContext()
        updateSnapshot()
        return .failure(recorded)
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
        if transaction.string("presentationFamily") != nil {
            group.setValue(transaction.string("presentationFamily"), forKey: "presentationFamily")
            group.setValue(transaction.value(forKey: "presentationVersion"), forKey: "presentationVersion")
            group.setValue(transaction.value(forKey: "presentationPayload"), forKey: "presentationPayload")
            group.setValue(transaction.value(forKey: "presentationDigest"), forKey: "presentationDigest")
        }
        let finalizedMembers = try transactionMembers(transaction)
        for member in finalizedMembers {
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
        // Action payloads are the accepted historical material. The prepared
        // delivery members are terminal duplicates and no longer aid recovery.
        for member in finalizedMembers { context.delete(member) }
        switch kind {
        case .command:
            for row in try ordinaryGroups(state: "undone") { row.setValue("branched", forKey: "state") }
        case .undo, .redo:
            if let key = transaction.string("targetGroupID"),
               let target = try groupRecord(key: key) {
                target.setValue(kind == .undo ? "undone" : "applied", forKey: "state")
            }
        }
        transaction.setValue("accepted", forKey: "stage")
        transaction.setValue(nil, forKey: "presentationPayload")
        transaction.setValue(nil, forKey: "presentationDigest")
        let scopeRow = try scopeRecord()
        group.setValue(scopeRow.int64("latestAcceptedSequence"), forKey: "previousAcceptedSequence")
        scopeRow.setValue(transaction.int64("sequence"), forKey: "latestAcceptedSequence")
        scopeRow.setValue(scopeRow.int64("committedVersion") + 1, forKey: "committedVersion")
        try saveContext()
        updateSnapshot()
        let token = try token(for: transaction)
        return .accepted(HistoryReceipt(token: token, groupID: try group.uuid("key")))
    }

    func finalizeRejected(_ transaction: NSManagedObject) throws -> HistoryResult {
        let kind = HistoryDeliveryKind(rawValue: transaction.string("kind") ?? "") ?? .command
        if kind != .command, let targetKey = transaction.string("targetGroupID"),
           let target = try groupRecord(key: targetKey) {
            target.setValue("invalid", forKey: "state")
        }
        transaction.setValue("rejected", forKey: "stage")
        for member in try fetch("HistoryMemberRecord", predicate: NSPredicate(
            format: "transaction == %@", transaction)) { context.delete(member) }
        transaction.setValue(nil, forKey: "presentationPayload")
        transaction.setValue(nil, forKey: "presentationDigest")
        try saveContext()
        updateSnapshot()
        return .rejected
    }
}
