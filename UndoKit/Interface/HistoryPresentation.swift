// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryEngine {
    /// Identity and accepted position observed together on this scope's actor.
    public func readIdentity() throws -> HistoryReadIdentity {
        guard !closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        let scopeRow = try scopeRecord()
        let floor = scopeRow.int64("undoFloorSequence")
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryGroupRecord")
        request.predicate = NSPredicate(format: "scopeKey == %@ AND sequence >= %@",
                                        scope.uuidString, NSNumber(value: floor))
        request.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: false)]
        request.fetchLimit = 1
        let latest = try context.fetch(request).first
        let currentAccepted = scopeRow.int64("latestAcceptedSequence") >= floor
            ? scopeRow.int64("latestAcceptedSequence") : 0
        guard (latest?.int64("sequence") ?? 0) == currentAccepted else {
            throw HistoryFailure(.corruptHistory, stage: .reconciliation, disposition: .usable)
        }
        return HistoryReadIdentity(scope: scope, generation: try scopeRow.uuid("generationID"),
            committedVersion: scopeRow.int64("committedVersion"),
            latestAcceptedSequence: currentAccepted,
            latestGroupID: try latest?.uuid("key"))
    }

    /// Retrieves only a small encoded display value; absent data uses a generic label.
    public func presentation(forGroup id: UUID) throws -> HistoryPayload? {
        guard !closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        let rows = try fetch("HistoryGroupRecord", predicate: NSPredicate(
            format: "scopeKey == %@ AND key == %@", scope.uuidString, id.uuidString))
        guard let row = rows.first else { return nil }
        guard row.string("presentationFamily") != nil else { return nil }
        let value = try payload(on: row, prefix: "presentation")
        guard value.data.count <= 4_096 else {
            throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
        }
        return value
    }

    /// Resolve native menu names through the host's metadata codec. The returned
    /// snapshot and names are read in one actor turn for `NativeHistoryRouter.update`.
    public func nativeActionNames(
        resolve: (HistoryPayload) throws -> String?
    ) throws -> (snapshot: HistorySnapshot, names: HistoryNativeActionNames) {
        guard !closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        let undoRow = try eligibleGroup(for: .undo)
        let redoRow = try eligibleGroup(for: .redo)
        func name(_ row: NSManagedObject?) throws -> String {
            guard let row, let id = try? row.uuid("key"),
                  let presentation = try? presentation(forGroup: id) else { return "" }
            return (try? resolve(presentation)) ?? ""
        }
        return (snapshot, try HistoryNativeActionNames(undo: name(undoRow), redo: name(redoRow)))
    }
}
