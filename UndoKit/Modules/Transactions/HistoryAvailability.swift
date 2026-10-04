// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

import CoreData

extension HistoryTransactionCoordinator {
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
        let canUndo = try sessionGroups.contains(where: { $0.applied }) || history.eligibleGroup(for: .undo) != nil
        let canRedo = try sessionGroups.contains(where: { !$0.applied }) || history.eligibleGroup(for: .redo) != nil
        publishSnapshot(canUndo: !suspended && !store.writeFailed && canUndo,
                        canRedo: !suspended && !store.writeFailed && canRedo,
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
