// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryTransactionCoordinator {
    func eligibleInverse(for kind: HistoryDeliveryKind) throws -> HistoryPositionPolicy.Target? {
        let retained = try history.positionGroups()
        return positionPolicy.eligibleInverse(
            for: kind, retainedGroups: retained.groups,
            retainedHistoryInvalidated: retained.invalidated)
    }

    func updateSnapshot() {
        if store.writeFailed {
            publishSnapshot(canUndo: false, canRedo: false, isSuspended: true,
                            hasPending: hasPending,
                            generation: snapshot.generation)
            return
        }
        guard !closed else {
            publishSnapshot(canUndo: false, canRedo: false,
                            isSuspended: snapshot.isSuspended, hasPending: false,
                            generation: snapshot.generation)
            return
        }
        do { try refreshSnapshot() } catch { suspend() }
    }

    func refreshSnapshot() throws {
        let row = try history.scopeRecord()
        let suspended = row.suspended
        let canUndo = try eligibleInverse(for: .undo) != nil
        let canRedo = try eligibleInverse(for: .redo) != nil
        let available = !suspended && !store.writeFailed && !closing && !closed && !store.closing
        publishSnapshot(canUndo: available && canUndo,
                        canRedo: available && canRedo,
                        isSuspended: suspended || store.writeFailed,
                        hasPending: hasPending,
                        generation: try row.uuid(row.generationID))
    }

    func suspend() {
        context.rollback()
        if let row = try? history.scopeRecord() {
            row.suspended = true
            try? history.saveContext()
        }
        publishSnapshot(canUndo: false, canRedo: false, isSuspended: true,
                        hasPending: hasPending,
                        generation: (try? history.scopeRecord().generationUUID()) ?? snapshot.generation)
    }

    func unsuspend() {
        if let row = try? history.scopeRecord() {
            row.suspended = false
            try? history.saveContext()
        }
        updateSnapshot()
    }

    func publishSnapshot(canUndo: Bool, canRedo: Bool, isSuspended: Bool,
                         hasPending: Bool, generation: UUID?) {
        let candidate = HistorySnapshot(canUndo: canUndo, canRedo: canRedo,
                                        isSuspended: isSuspended, hasPending: hasPending,
                                        scope: scope, generation: generation, version: snapshot.version)
        guard candidate != snapshot else { return }
        let value = HistorySnapshot(canUndo: canUndo, canRedo: canRedo,
                                    isSuspended: isSuspended, hasPending: hasPending,
                                    scope: scope, generation: generation, version: snapshot.version + 1)
        snapshot = value
        snapshotDidChange?(value)
    }
}
