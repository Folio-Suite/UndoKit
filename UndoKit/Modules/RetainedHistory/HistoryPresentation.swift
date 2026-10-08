// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension RetainedHistory {
    func readIdentity() throws -> HistoryReadIdentity {
        guard !activity.closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        let scopeRow = try history.scopeRecord()
        let floor = scopeRow.undoFloorSequence
        let request = HistoryGroupRecord.fetchRequest()
        request.predicate = NSPredicate(format: "\(#keyPath(HistoryGroupRecord.scopeKey)) == %@ AND \(#keyPath(HistoryGroupRecord.sequence)) >= %@",
                                        scope.uuidString, NSNumber(value: floor))
        request.sortDescriptors = [NSSortDescriptor(key: #keyPath(HistoryGroupRecord.sequence), ascending: false)]
        request.fetchLimit = 1
        let latest = try context.fetch(request).first
        let currentAccepted = scopeRow.latestAcceptedSequence >= floor
            ? scopeRow.latestAcceptedSequence : 0
        guard (latest?.sequence ?? 0) == currentAccepted else {
            throw HistoryFailure(.corruptHistory, stage: .reconciliation, disposition: .usable)
        }
        return HistoryReadIdentity(scope: scope, generation: try scopeRow.uuid(scopeRow.generationID),
            committedVersion: scopeRow.committedVersion,
            latestAcceptedSequence: currentAccepted,
            latestGroupID: try latest?.uuid(latest?.key))
    }

    func presentation(forGroup id: UUID) throws -> HistoryPayload? {
        guard !activity.closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        let rows = try history.fetch(HistoryGroupRecord.self, predicate: NSPredicate(
            format: "\(#keyPath(HistoryGroupRecord.scopeKey)) == %@ AND \(#keyPath(HistoryGroupRecord.key)) == %@", scope.uuidString, id.uuidString))
        guard let row = rows.first else { return nil }
        guard row.presentationFamily != nil else { return nil }
        let value = try history.presentationPayload(on: row)
        guard value.data.count <= 4_096 else {
            throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
        }
        return value
    }

    func nativeActionNames(
        resolve: (HistoryPayload) throws -> String?
    ) throws -> (snapshot: HistorySnapshot, names: HistoryNativeActionNames) {
        guard !activity.closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        let undoRow = try history.eligibleGroup(for: .undo)
        let redoRow = try history.eligibleGroup(for: .redo)
        func name(_ row: HistoryGroupRecord?) throws -> String {
            guard let row, let id = try? row.uuid(row.key),
                  let presentation = try? presentation(forGroup: id) else { return "" }
            return (try? resolve(presentation)) ?? ""
        }
        return (snapshot, try HistoryNativeActionNames(undo: name(undoRow), redo: name(redoRow)))
    }
}
