// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import CoreData
import Foundation

public enum CommandKind: String, Codable, Sendable { case ordinary, undo, redo }
public struct Member: Codable, Equatable, Sendable {
    public let id: String
    public let delta: Int
    public let targetMemberID: String?
    public let compensationActionID: String?
    public init(id: String, delta: Int, targetMemberID: String? = nil, compensationActionID: String? = nil) {
        self.id = id; self.delta = delta; self.targetMemberID = targetMemberID
        self.compensationActionID = compensationActionID
    }
}
public struct Command: Codable, Equatable, Sendable {
    public let scope: String
    public let id: String
    public let fingerprint: String
    public let kind: CommandKind
    public let groupID: String
    public let members: [Member]
    public init(scope: String, id: String, fingerprint: String, kind: CommandKind,
                delta: Int, groupID: String? = nil, targetMemberID: String? = nil,
                compensationActionID: String? = nil) {
        self.init(scope: scope, id: id, fingerprint: fingerprint, kind: kind,
                  groupID: groupID ?? id, members: [Member(id: id, delta: delta, targetMemberID: targetMemberID,
                                                        compensationActionID: compensationActionID)])
    }
    public init(scope: String, id: String, fingerprint: String, kind: CommandKind,
                groupID: String, members: [Member]) {
        self.scope = scope; self.id = id; self.fingerprint = fingerprint
        self.kind = kind; self.groupID = groupID; self.members = members
    }
}
public struct Token: Equatable, Sendable {
    public let scope: String
    public let id: String
    public let generation: Int64
    public let sequence: Int64
}
public enum Outcome: String, Codable, Sendable { case accepted, rejected, unresolved }
public enum TransactionPhase: String, Sendable {
    case prepared, deliveryStarted, acceptancePending, rejectionPending, unresolved, finalized, cancelled
}
public enum HistoryFault: String, Sendable {
    case prepare, deliveryStarted, acceptance, rejection, finalization, invalidation
}
public enum HostFault: Sendable { case beforeSave, afterSave }
public enum ProbeError: Error, Equatable {
    case conflict, busy, invalidToken, invalidTransition, injectedFailure, unresolved
    case invalidGroup, storage
}
public struct ActionSnapshot: Equatable, Sendable {
    public let id: String
    public let groupID: String
    public let memberID: String
    public let targetMemberID: String?
    public let compensationActionID: String?
    public let kind: CommandKind
    public let valid: Bool
}
public struct ScopeSnapshot: Equatable, Sendable {
    public let phase: TransactionPhase?
    public let actions: [ActionSnapshot]
    public let undoAvailable: Bool
    public let redoAvailable: Bool
}
public struct HostReceipt: Codable, Equatable, Sendable {
    public let fingerprint: String
    public let outcome: Outcome
    public let memberIDs: [String]
    public let targetMemberIDs: [String?]
    public let compensationActionIDs: [String?]
}
private struct HostDocument: Codable {
    var values: [String: Int] = [:]
    var receipts: [String: HostReceipt] = [:]
}

/// A disposable host fixture. A single atomic replacement commits semantic state and receipt.
@MainActor public final class HostStore {
    private let url: URL
    public private(set) var deliveryAttempts = 0
    public var fault: HostFault?
    public var nextOutcome: Outcome = .accepted
    public var malformedMemberEvidence = false
    private init(url: URL) { self.url = url }
    public static func open(directory: URL) throws -> HostStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return HostStore(url: directory.appendingPathComponent("host.json"))
    }
    private func read() throws -> HostDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return HostDocument() }
        return try JSONDecoder().decode(HostDocument.self, from: Data(contentsOf: url))
    }
    private func key(_ scope: String, _ id: String) -> String { scope + "\u{1F}" + id }
    public func value(scope: String) throws -> Int { try read().values[scope] ?? 0 }
    public func lookup(scope: String, id: String) throws -> HostReceipt? {
        try read().receipts[key(scope, id)]
    }
    public func apply(_ command: Command) throws -> HostReceipt {
        deliveryAttempts += 1
        guard !command.scope.contains("\u{1F}"), !command.id.contains("\u{1F}") else { throw ProbeError.conflict }
        var document = try read()
        let identity = key(command.scope, command.id)
        if let prior = document.receipts[identity] {
            guard prior.fingerprint == command.fingerprint else { throw ProbeError.conflict }
            return prior
        }
        if fault == .beforeSave { fault = nil; throw ProbeError.injectedFailure }
        let outcome = nextOutcome
        nextOutcome = .accepted
        let evidence = outcome == .accepted
            ? (malformedMemberEvidence ? Array(command.members.dropLast()) : command.members)
            : []
        malformedMemberEvidence = false
        let receipt = HostReceipt(fingerprint: command.fingerprint, outcome: outcome,
                                  memberIDs: evidence.map(\.id), targetMemberIDs: evidence.map(\.targetMemberID),
                                  compensationActionIDs: evidence.map(\.compensationActionID))
        if outcome == .accepted {
            document.values[command.scope, default: 0] += command.members.reduce(0) { $0 + $1.delta }
        }
        if outcome != .unresolved { document.receipts[identity] = receipt }
        try JSONEncoder().encode(document).write(to: url, options: .atomic)
        if fault == .afterSave { fault = nil; throw ProbeError.injectedFailure }
        return receipt
    }
}

/// Disposable Core Data transaction server; managed objects never cross this interface.
@MainActor public final class RecoveryProbe {
    private let container: NSPersistentContainer
    private var context: NSManagedObjectContext { container.viewContext }
    public var fault: HistoryFault?
    private init(container: NSPersistentContainer) { self.container = container }
    public func close() throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
    public static func open(directory: URL) throws -> RecoveryProbe {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = NSPersistentContainer(name: "RecoveryHistory", managedObjectModel: model())
        let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("history.sqlite"))
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if loadError != nil { throw ProbeError.storage }
        return RecoveryProbe(container: container)
    }
    private static func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
        let value = NSAttributeDescription(); value.name = name; value.attributeType = type
        value.isOptional = optional; return value
    }
    private static func entity(_ name: String, _ attributes: [NSAttributeDescription]) -> NSEntityDescription {
        let value = NSEntityDescription(); value.name = name; value.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        value.properties = attributes; return value
    }
    private static func model() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let transaction = entity("Transaction", [attribute("key", .stringAttributeType), attribute("scope", .stringAttributeType),
            attribute("id", .stringAttributeType), attribute("fingerprint", .stringAttributeType),
            attribute("kind", .stringAttributeType), attribute("groupID", .stringAttributeType),
            attribute("generation", .integer64AttributeType), attribute("sequence", .integer64AttributeType),
            attribute("phase", .stringAttributeType)])
        transaction.uniquenessConstraints = [["key"]]
        let member = entity("Member", [attribute("transactionKey", .stringAttributeType),
            attribute("ordinal", .integer64AttributeType), attribute("memberID", .stringAttributeType),
            attribute("targetMemberID", .stringAttributeType, optional: true),
            attribute("compensationActionID", .stringAttributeType, optional: true),
            attribute("delta", .integer64AttributeType)])
        member.uniquenessConstraints = [["transactionKey", "ordinal"]]
        let action = entity("Action", [attribute("scope", .stringAttributeType), attribute("transactionKey", .stringAttributeType),
            attribute("ordinal", .integer64AttributeType), attribute("memberID", .stringAttributeType),
            attribute("targetMemberID", .stringAttributeType, optional: true),
            attribute("compensationActionID", .stringAttributeType, optional: true),
            attribute("groupID", .stringAttributeType), attribute("kind", .stringAttributeType)])
        action.uniquenessConstraints = [["transactionKey", "ordinal"]]
        let eligibility = entity("GroupEligibility", [attribute("key", .stringAttributeType),
            attribute("scope", .stringAttributeType), attribute("groupID", .stringAttributeType),
            attribute("state", .stringAttributeType), attribute("sequence", .integer64AttributeType),
            attribute("latestCompensationKey", .stringAttributeType, optional: true)])
        eligibility.uniquenessConstraints = [["key"]]
        model.entities = [transaction, member, action, eligibility]; return model
    }
    private func key(_ scope: String, _ id: String) -> String { scope + "\u{1F}" + id }
    private func actionID(_ transactionKey: String, _ ordinal: Int64) -> String {
        transactionKey + "#" + String(ordinal)
    }
    private func fetch(_ entity: String, predicate: NSPredicate? = nil, sort: [NSSortDescriptor] = []) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = predicate; request.sortDescriptors = sort
        return try context.fetch(request)
    }
    private func transaction(_ scope: String, _ id: String) throws -> NSManagedObject? {
        try fetch("Transaction", predicate: NSPredicate(format: "key == %@", key(scope, id))).first
    }
    private func phase(_ record: NSManagedObject) -> TransactionPhase {
        TransactionPhase(rawValue: record.value(forKey: "phase") as! String)!
    }
    private func save(_ stage: HistoryFault) throws {
        if fault == stage { fault = nil; context.rollback(); throw ProbeError.injectedFailure }
        do { try context.save() } catch { context.rollback(); throw ProbeError.storage }
    }
    private func check(_ token: Token) throws -> NSManagedObject {
        guard let record = try transaction(token.scope, token.id),
              record.value(forKey: "generation") as? Int64 == token.generation,
              record.value(forKey: "sequence") as? Int64 == token.sequence else { throw ProbeError.invalidToken }
        return record
    }
    private func members(_ token: Token) throws -> [NSManagedObject] {
        try fetch("Member", predicate: NSPredicate(format: "transactionKey == %@", key(token.scope, token.id)),
                  sort: [NSSortDescriptor(key: "ordinal", ascending: true)])
    }
    private func eligibility(_ scope: String, _ groupID: String) throws -> NSManagedObject? {
        try fetch("GroupEligibility", predicate: NSPredicate(format: "key == %@", key(scope, groupID))).first
    }
    public func prepare(_ command: Command) throws -> Token {
        guard !command.scope.isEmpty, !command.id.isEmpty, !command.fingerprint.isEmpty,
              !command.scope.contains("\u{1F}"), !command.id.contains("\u{1F}"),
              !command.members.isEmpty, Set(command.members.map(\.id)).count == command.members.count else { throw ProbeError.invalidGroup }
        if let existing = try transaction(command.scope, command.id) {
            guard existing.value(forKey: "fingerprint") as? String == command.fingerprint else { throw ProbeError.conflict }
            return Token(scope: command.scope, id: command.id,
                         generation: existing.value(forKey: "generation") as! Int64,
                         sequence: existing.value(forKey: "sequence") as! Int64)
        }
        let active = try fetch("Transaction", predicate: NSPredicate(format: "scope == %@ AND phase != %@ AND phase != %@", command.scope,
            TransactionPhase.finalized.rawValue, TransactionPhase.cancelled.rawValue))
        guard active.isEmpty else { throw ProbeError.busy }
        if command.kind == .ordinary {
            guard command.members.allSatisfy({ $0.targetMemberID == nil && $0.compensationActionID == nil }) else {
                throw ProbeError.invalidGroup
            }
            guard try eligibility(command.scope, command.groupID) == nil else { throw ProbeError.conflict }
        } else {
            let required = command.kind == .undo ? "undoable" : "redoable"
            let candidates = try fetch("GroupEligibility", predicate: NSPredicate(format: "scope == %@ AND state == %@", command.scope, required))
            let expected = command.kind == .undo
                ? candidates.max { ($0.value(forKey: "sequence") as! Int64) < ($1.value(forKey: "sequence") as! Int64) }
                : candidates.min { ($0.value(forKey: "sequence") as! Int64) < ($1.value(forKey: "sequence") as! Int64) }
            guard expected?.value(forKey: "groupID") as? String == command.groupID else {
                throw ProbeError.invalidTransition
            }
            let originalMembers = try fetch("Action", predicate: NSPredicate(format: "scope == %@ AND groupID == %@ AND kind == %@",
                command.scope, command.groupID, CommandKind.ordinary.rawValue),
                sort: [NSSortDescriptor(key: "ordinal", ascending: true)])
            let targetPlan = originalMembers.map { $0.value(forKey: "memberID") as! String }
            let requiredPlan = command.kind == .undo ? Array(targetPlan.reversed()) : targetPlan
            guard !requiredPlan.isEmpty, command.members.map(\.targetMemberID) == requiredPlan.map(Optional.some) else {
                throw ProbeError.invalidGroup
            }
            if command.kind == .undo {
                guard command.members.allSatisfy({ $0.compensationActionID == nil }) else { throw ProbeError.invalidGroup }
            } else {
                guard let compensationKey = try eligibility(command.scope, command.groupID)?
                    .value(forKey: "latestCompensationKey") as? String else { throw ProbeError.invalidGroup }
                let compensation = try fetch("Action", predicate: NSPredicate(format: "transactionKey == %@ AND kind == %@",
                    compensationKey, CommandKind.undo.rawValue))
                let byTarget = Dictionary(uniqueKeysWithValues: compensation.map {
                    ($0.value(forKey: "targetMemberID") as! String,
                     actionID(compensationKey, $0.value(forKey: "ordinal") as! Int64))
                })
                let expectedCompensation = requiredPlan.map { byTarget[$0] }
                guard expectedCompensation.allSatisfy({ $0 != nil }),
                      command.members.map(\.compensationActionID) == expectedCompensation else {
                    throw ProbeError.invalidGroup
                }
            }
        }
        let prior = try fetch("Transaction", predicate: NSPredicate(format: "scope == %@", command.scope))
        let sequence = (prior.map { $0.value(forKey: "sequence") as! Int64 }.max() ?? 0) + 1
        let record = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: context)
        record.setValue(key(command.scope, command.id), forKey: "key")
        record.setValue(command.scope, forKey: "scope"); record.setValue(command.id, forKey: "id")
        record.setValue(command.fingerprint, forKey: "fingerprint"); record.setValue(command.kind.rawValue, forKey: "kind")
        record.setValue(command.groupID, forKey: "groupID"); record.setValue(Int64(1), forKey: "generation")
        record.setValue(sequence, forKey: "sequence"); record.setValue(TransactionPhase.prepared.rawValue, forKey: "phase")
        for (ordinal, item) in command.members.enumerated() {
            let member = NSEntityDescription.insertNewObject(forEntityName: "Member", into: context)
            member.setValue(key(command.scope, command.id), forKey: "transactionKey")
            member.setValue(Int64(ordinal), forKey: "ordinal"); member.setValue(item.id, forKey: "memberID")
            member.setValue(item.targetMemberID, forKey: "targetMemberID")
            member.setValue(item.compensationActionID, forKey: "compensationActionID")
            member.setValue(Int64(item.delta), forKey: "delta")
        }
        try save(.prepare)
        return Token(scope: command.scope, id: command.id, generation: 1, sequence: sequence)
    }
    public func cancelBeforeDelivery(_ token: Token) throws {
        let record = try check(token)
        guard phase(record) == .prepared else { throw ProbeError.invalidTransition }
        record.setValue(TransactionPhase.cancelled.rawValue, forKey: "phase")
        try save(.finalization)
    }
    public func markDeliveryStarted(_ token: Token) throws {
        let record = try check(token)
        guard phase(record) == .prepared else { throw ProbeError.invalidTransition }
        record.setValue(TransactionPhase.deliveryStarted.rawValue, forKey: "phase")
        try save(.deliveryStarted)
    }
    private func command(_ token: Token) throws -> Command {
        let record = try check(token)
        let items = try members(token).map { Member(id: $0.value(forKey: "memberID") as! String,
                                                   delta: Int($0.value(forKey: "delta") as! Int64),
                                                   targetMemberID: $0.value(forKey: "targetMemberID") as? String,
                                                   compensationActionID: $0.value(forKey: "compensationActionID") as? String) }
        return Command(scope: token.scope, id: token.id, fingerprint: record.value(forKey: "fingerprint") as! String,
                       kind: CommandKind(rawValue: record.value(forKey: "kind") as! String)!,
                       groupID: record.value(forKey: "groupID") as! String, members: items)
    }
    public func deliver(_ token: Token, host: HostStore) throws {
        guard phase(try check(token)) == .deliveryStarted else { throw ProbeError.invalidTransition }
        _ = try host.apply(command(token))
        try reconcile(token, host: host)
    }
    public func reconcile(_ token: Token, host: HostStore) throws {
        let record = try check(token)
        guard phase(record) == .deliveryStarted || phase(record) == .unresolved else { throw ProbeError.invalidTransition }
        let command = try command(token)
        guard let receipt = try host.lookup(scope: token.scope, id: token.id),
              receipt.fingerprint == command.fingerprint else {
            record.setValue(TransactionPhase.unresolved.rawValue, forKey: "phase")
            try save(.acceptance); throw ProbeError.unresolved
        }
        if receipt.outcome == .accepted {
            guard receipt.memberIDs == command.members.map(\.id),
                  receipt.targetMemberIDs == command.members.map(\.targetMemberID),
                  receipt.compensationActionIDs == command.members.map(\.compensationActionID) else {
                record.setValue(TransactionPhase.unresolved.rawValue, forKey: "phase")
                try save(.acceptance); throw ProbeError.unresolved
            }
            record.setValue(TransactionPhase.acceptancePending.rawValue, forKey: "phase")
            try save(.acceptance)
        } else if receipt.outcome == .rejected {
            record.setValue(TransactionPhase.rejectionPending.rawValue, forKey: "phase")
            try save(.rejection)
        } else {
            record.setValue(TransactionPhase.unresolved.rawValue, forKey: "phase")
            try save(.acceptance); throw ProbeError.unresolved
        }
    }
    public func finalize(_ token: Token) throws -> Outcome {
        let record = try check(token)
        let state = phase(record)
        if state == .finalized {
            return (try fetch("Action", predicate: NSPredicate(format: "transactionKey == %@", key(token.scope, token.id))).isEmpty) ? .rejected : .accepted
        }
        guard state == .acceptancePending || state == .rejectionPending else { throw ProbeError.invalidTransition }
        let command = try command(token)
        if state == .acceptancePending {
            for (ordinal, member) in command.members.enumerated() {
                let action = NSEntityDescription.insertNewObject(forEntityName: "Action", into: context)
                action.setValue(command.scope, forKey: "scope")
                action.setValue(key(command.scope, command.id), forKey: "transactionKey")
                action.setValue(Int64(ordinal), forKey: "ordinal")
                action.setValue(member.id, forKey: "memberID")
                action.setValue(member.targetMemberID, forKey: "targetMemberID")
                action.setValue(member.compensationActionID, forKey: "compensationActionID")
                action.setValue(command.groupID, forKey: "groupID")
                action.setValue(command.kind.rawValue, forKey: "kind")
            }
            if command.kind == .ordinary {
                let abandoned = try fetch("GroupEligibility", predicate: NSPredicate(format: "scope == %@ AND state == %@", command.scope, "redoable"))
                for group in abandoned { group.setValue("invalidated", forKey: "state") }
                let group = NSEntityDescription.insertNewObject(forEntityName: "GroupEligibility", into: context)
                group.setValue(key(command.scope, command.groupID), forKey: "key")
                group.setValue(command.scope, forKey: "scope")
                group.setValue(command.groupID, forKey: "groupID")
                group.setValue("undoable", forKey: "state")
                group.setValue(token.sequence, forKey: "sequence")
            } else {
                let group = try eligibility(command.scope, command.groupID)!
                group.setValue(command.kind == .undo ? "redoable" : "undoable", forKey: "state")
                if command.kind == .undo { group.setValue(key(command.scope, command.id), forKey: "latestCompensationKey") }
            }
        } else if command.kind != .ordinary {
            try eligibility(command.scope, command.groupID)?.setValue("invalidated", forKey: "state")
        }
        record.setValue(TransactionPhase.finalized.rawValue, forKey: "phase")
        try save(state == .rejectionPending && command.kind != .ordinary ? .invalidation : .finalization)
        return state == .acceptancePending ? .accepted : .rejected
    }
    @discardableResult public func submit(_ command: Command, host: HostStore) throws -> Outcome {
        let token = try prepare(command)
        let state = phase(try check(token))
        if state == .prepared { try markDeliveryStarted(token); try deliver(token, host: host) }
        let next = phase(try check(token))
        if next == .deliveryStarted || next == .unresolved { try reconcile(token, host: host) }
        return try finalize(token)
    }
    public func resumePrepared(_ token: Token, host: HostStore) throws -> Outcome {
        try markDeliveryStarted(token)
        try deliver(token, host: host)
        return try finalize(token)
    }
    public func recover(host: HostStore) throws {
        let active = try fetch("Transaction", predicate: NSPredicate(format: "phase != %@ AND phase != %@",
            TransactionPhase.finalized.rawValue, TransactionPhase.cancelled.rawValue),
            sort: [NSSortDescriptor(key: "scope", ascending: true), NSSortDescriptor(key: "sequence", ascending: true)])
        var foundUnresolved = false
        for record in active {
            let token = Token(scope: record.value(forKey: "scope") as! String, id: record.value(forKey: "id") as! String,
                              generation: record.value(forKey: "generation") as! Int64,
                              sequence: record.value(forKey: "sequence") as! Int64)
            do {
                switch phase(record) {
                case .deliveryStarted, .unresolved: try reconcile(token, host: host); _ = try finalize(token)
                case .acceptancePending, .rejectionPending: _ = try finalize(token)
                default: break
                }
            } catch ProbeError.unresolved {
                foundUnresolved = true
            }
        }
        if foundUnresolved { throw ProbeError.unresolved }
    }
    public func snapshot(scope: String) throws -> ScopeSnapshot {
        let transactions = try fetch("Transaction", predicate: NSPredicate(format: "scope == %@", scope))
        let active = transactions.first { phase($0) != .finalized && phase($0) != .cancelled }
        let actions = try fetch("Action", predicate: NSPredicate(format: "scope == %@", scope),
                                sort: [NSSortDescriptor(key: "transactionKey", ascending: true), NSSortDescriptor(key: "ordinal", ascending: true)])
        let groups = try fetch("GroupEligibility", predicate: NSPredicate(format: "scope == %@", scope))
        let states = Dictionary(uniqueKeysWithValues: groups.map { ($0.value(forKey: "groupID") as! String, $0.value(forKey: "state") as! String) })
        let snapshots = actions.map { action in
            let kind = CommandKind(rawValue: action.value(forKey: "kind") as! String)!
            let groupID = action.value(forKey: "groupID") as! String
            return ActionSnapshot(id: actionID(action.value(forKey: "transactionKey") as! String,
                                               action.value(forKey: "ordinal") as! Int64),
                                  groupID: groupID,
                                  memberID: action.value(forKey: "memberID") as! String,
                                  targetMemberID: action.value(forKey: "targetMemberID") as? String,
                                  compensationActionID: action.value(forKey: "compensationActionID") as? String,
                                  kind: kind,
                                  valid: kind == .ordinary ? states[groupID] == "undoable" : kind == .undo && states[groupID] == "redoable") }
        let available = active == nil
        return ScopeSnapshot(phase: active.map(phase), actions: snapshots,
                             undoAvailable: available && states.values.contains("undoable"),
                             redoAvailable: available && states.values.contains("redoable"))
    }
}
