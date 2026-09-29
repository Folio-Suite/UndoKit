// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import Foundation

public struct ProofGroup: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let before: String
    public let after: String

    public init(id: UUID = UUID(), name: String, before: String, after: String) {
        self.id = id
        self.name = name
        self.before = before
        self.after = after
    }
}

public struct ProofHistory: Codable, Sendable {
    public let scope: String
    public var generation: UUID
    public private(set) var version: UInt64
    public private(set) var content: String
    public private(set) var groups: [ProofGroup]
    public private(set) var position: Int
    public private(set) var invalidUndoIDs: Set<UUID>
    public private(set) var invalidRedoIDs: Set<UUID>
    public private(set) var suspended: Bool

    public init(scope: String) {
        self.scope = scope
        generation = UUID()
        version = 0
        content = ""
        groups = []
        position = 0
        invalidUndoIDs = []
        invalidRedoIDs = []
        suspended = false
    }

    public var undoGroup: ProofGroup? {
        guard !suspended, position > 0 else { return nil }
        let group = groups[position - 1]
        return invalidUndoIDs.contains(group.id) ? nil : group
    }

    public var redoGroup: ProofGroup? {
        guard !suspended, position < groups.count else { return nil }
        let group = groups[position]
        return invalidRedoIDs.contains(group.id) ? nil : group
    }

    @discardableResult
    public mutating func acceptEdit(_ next: String, name: String) -> ProofGroup? {
        guard !suspended, next != content else { return nil }
        if position < groups.count { groups.removeSubrange(position...) }
        let group = ProofGroup(name: name, before: content, after: next)
        groups.append(group)
        position += 1
        content = next
        version += 1
        return group
    }

    @discardableResult
    public mutating func acceptUndo(expectedID: UUID) -> Bool {
        guard let group = undoGroup, group.id == expectedID else { return false }
        content = group.before
        position -= 1
        version += 1
        return true
    }

    @discardableResult
    public mutating func acceptRedo(expectedID: UUID) -> Bool {
        guard let group = redoGroup, group.id == expectedID else { return false }
        content = group.after
        position += 1
        version += 1
        return true
    }

    public mutating func reject(_ groupID: UUID, undo: Bool) {
        if undo { invalidUndoIDs.insert(groupID) }
        else { invalidRedoIDs.insert(groupID) }
        version += 1
    }

    public mutating func suspend() {
        suspended = true
        version += 1
    }

    public mutating func resolve() {
        suspended = false
        version += 1
    }

    public mutating func advanceAvailabilityVersion() {
        version += 1
    }
}

public struct Availability: Equatable, Sendable {
    public let scope: String
    public let generation: UUID
    public let version: UInt64
    public let undoID: UUID?
    public let redoID: UUID?
    public let undoName: String?
    public let redoName: String?
    public let pending: Bool
    public let suspended: Bool
    public let interference: Bool
}

public enum ProofOutcome: Equatable, Sendable {
    case acceptedUndo
    case acceptedRedo
    case rejected
    case unresolved
}

public enum ProofMode: String, CaseIterable, Sendable {
    case immediate = "Immediate"
    case delayed = "Delay 10s"
    case reject = "Reject"
    case unresolved = "Unresolved"
}

@MainActor
public final class NativeBridge {
    public private(set) var history: ProofHistory
    public private(set) var pending: (undo: Bool, groupID: UUID, origin: String)?
    public private(set) var interference = false
    public var onChange: ((ProofOutcome?, String?) -> Void)?

    public init(history: ProofHistory) { self.history = history }

    public var availability: Availability {
        Availability(
            scope: history.scope, generation: history.generation,
            version: history.version, undoID: pending == nil && !interference ? history.undoGroup?.id : nil,
            redoID: pending == nil && !interference ? history.redoGroup?.id : nil,
            undoName: pending == nil && !interference ? history.undoGroup?.name : nil,
            redoName: pending == nil && !interference ? history.redoGroup?.name : nil,
            pending: pending != nil, suspended: history.suspended, interference: interference
        )
    }

    @discardableResult
    public func acceptEdit(_ value: String, name: String) -> Bool {
        guard pending == nil, !interference else { return false }
        guard history.acceptEdit(value, name: name) != nil else { return false }
        onChange?(nil, nil)
        return true
    }

    @discardableResult
    public func begin(undo: Bool, origin: String) -> Bool {
        guard pending == nil, !interference, !history.suspended else { return false }
        guard let group = undo ? history.undoGroup : history.redoGroup else { return false }
        pending = (undo, group.id, origin)
        history.advanceAvailabilityVersion()
        onChange?(nil, origin)
        return true
    }

    @discardableResult
    public func finish(mode: ProofMode) -> ProofOutcome? {
        guard let request = pending else { return nil }
        pending = nil
        let result: ProofOutcome
        switch mode {
        case .immediate, .delayed:
            let accepted = request.undo
                ? history.acceptUndo(expectedID: request.groupID)
                : history.acceptRedo(expectedID: request.groupID)
            guard accepted else { history.suspend(); onChange?(.unresolved, request.origin); return .unresolved }
            result = request.undo ? .acceptedUndo : .acceptedRedo
        case .reject:
            history.reject(request.groupID, undo: request.undo)
            result = .rejected
        case .unresolved:
            history.suspend()
            result = .unresolved
        }
        onChange?(result, request.origin)
        return result
    }

    public func reconcileUnresolved() {
        history.resolve()
        onChange?(nil, nil)
    }

    public func detectUnknownRegistration() {
        interference = true
        history.advanceAvailabilityVersion()
        onChange?(nil, nil)
    }

    public func reconcileRegistration() {
        interference = false
        history.advanceAvailabilityVersion()
        onChange?(nil, nil)
    }
}
