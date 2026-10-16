// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

/// Owns the current session's position alongside the shared traversal rules
/// used to choose between transient effects and retained groups.
struct HistoryPositionPolicy {
    struct SessionGroup {
        let id: UUID
        let sequence: Int64
        let effects: [HistoryEffect]
        var applied = true
        var invalidated = false
    }

    enum Target {
        case session(SessionGroup)
        case retained(HistoryGroupRecord)
    }

    private(set) var sessionGroups: [SessionGroup] = []

    static func retainedTarget(
        for kind: HistoryDeliveryKind, groups: [HistoryGroupRecord]
    ) -> HistoryGroupRecord? {
        let candidates = groups.filter {
            kind == .undo ? $0.state == "applied" : $0.state == "undone"
        }
        switch kind {
        case .undo: return candidates.max(by: { $0.sequence < $1.sequence })
        case .redo: return candidates.min(by: { $0.sequence < $1.sequence })
        case .command: return nil
        }
    }

    func eligibleInverse(
        for kind: HistoryDeliveryKind,
        retainedGroups: [HistoryGroupRecord],
        retainedHistoryInvalidated: Bool
    ) -> Target? {
        guard !retainedHistoryInvalidated,
              !sessionGroups.contains(where: \.invalidated) else { return nil }

        let transient = sessionGroups.filter { kind == .undo ? $0.applied : !$0.applied }
        let retainedTarget = Self.retainedTarget(for: kind, groups: retainedGroups)
        switch kind {
        case .undo:
            let transientTarget = transient.max(by: { $0.sequence < $1.sequence })
            if let transientTarget, let retainedTarget {
                return transientTarget.sequence > retainedTarget.sequence
                    ? .session(transientTarget) : .retained(retainedTarget)
            }
            if let transientTarget { return .session(transientTarget) }
            return retainedTarget.map(Target.retained)
        case .redo:
            let transientTarget = transient.min(by: { $0.sequence < $1.sequence })
            if let transientTarget, let retainedTarget {
                return transientTarget.sequence < retainedTarget.sequence
                    ? .session(transientTarget) : .retained(retainedTarget)
            }
            if let transientTarget { return .session(transientTarget) }
            return retainedTarget.map(Target.retained)
        case .command:
            return nil
        }
    }

    mutating func accepted(
        kind: HistoryDeliveryKind, groupID: UUID, targetID: UUID?,
        sequence: Int64, effects: [HistoryEffect], maximumGroups: Int
    ) {
        switch kind {
        case .command:
            sessionGroups.removeAll(where: { !$0.applied && !$0.invalidated })
            sessionGroups.append(SessionGroup(id: groupID, sequence: sequence, effects: effects))
        case .undo, .redo:
            if let targetID, let index = sessionGroups.firstIndex(where: { $0.id == targetID }) {
                sessionGroups[index].applied = kind == .redo
            } else if let targetID {
                // A recording-off inverse of retained history becomes a transient
                // counterpart at this accepted position.
                let swapped = effects.map { effect in
                    HistoryEffect(memberID: effect.memberID, undo: effect.redo,
                                  redo: effect.undo, resources: effect.resources)
                }
                sessionGroups.append(SessionGroup(
                    id: targetID, sequence: sequence, effects: swapped,
                    applied: kind == .redo))
            }
        }
        while sessionGroups.count > maximumGroups,
              let index = sessionGroups.firstIndex(where: { !$0.invalidated }) {
            sessionGroups.remove(at: index)
        }
    }

    func acceptedRetained(
        kind: HistoryDeliveryKind,
        group: HistoryGroupRecord,
        target: HistoryGroupRecord?,
        redoBranch: [HistoryGroupRecord]
    ) {
        group.state = kind == .command ? "applied" : "historical"
        switch kind {
        case .command:
            for row in redoBranch { row.state = "branched" }
        case .undo: target?.state = "undone"
        case .redo: target?.state = "applied"
        }
    }

    func prepareRejection(kind: HistoryDeliveryKind, retainedTarget: HistoryGroupRecord?) {
        guard kind != .command else { return }
        retainedTarget?.state = "invalid"
    }

    func acceptTransientBoundary(sequence: Int64, scopeRow: HistoryScopeRecord) {
        if scopeRow.offStartSequence > 0,
           sequence >= scopeRow.offStartSequence,
           scopeRow.undoFloorSequence < scopeRow.offStartSequence {
            scopeRow.undoFloorSequence = sequence
        }
    }

    mutating func changeRecordingBoundary(
        enabled: Bool, hadOffAction: Bool, nextSequence: Int64,
        scopeRow: HistoryScopeRecord
    ) {
        scopeRow.recordingEnabled = enabled
        if enabled {
            if hadOffAction { scopeRow.undoFloorSequence = nextSequence }
            scopeRow.offStartSequence = 0
        } else {
            scopeRow.offStartSequence = nextSequence
        }
    }

    mutating func commitRecordingBoundary(enabled: Bool) {
        if enabled { crossedIntoRecording() }
    }

    mutating func rejected(targetID: UUID?) {
        guard let targetID,
              let index = sessionGroups.firstIndex(where: { $0.id == targetID }) else { return }
        sessionGroups[index].invalidated = true
    }

    mutating func crossedIntoRecording() {
        sessionGroups.removeAll()
    }

    mutating func retiredGeneration() {
        sessionGroups.removeAll()
    }
}
