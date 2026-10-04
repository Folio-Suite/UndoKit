// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension RetainedHistory {
    @discardableResult func holdState(_ checkpointID: UUID, id: UUID = UUID()) throws -> HistoryRetentionHold {
        try activity.requireIdle()
        guard try checkpoint(id: checkpointID) != nil else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        return try insertHold(id: id, kind: .state(checkpointID: checkpointID))
    }

    @discardableResult func holdDetail(from firstGroupID: UUID, through lastGroupID: UUID,
                                       id: UUID = UUID()) throws -> HistoryRetentionHold {
        try activity.requireIdle()
        guard let first = try history.groupRecord(key: firstGroupID.uuidString),
              let last = try history.groupRecord(key: lastGroupID.uuidString),
              first.scopeKey == scope.uuidString,
              last.scopeKey == scope.uuidString,
              first.sequence <= last.sequence else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        let lower = first.sequence
        let upper = last.sequence
        let gaps = try history.fetch(HistoryGapRecord.self, predicate: NSPredicate(
            format: "\(#keyPath(HistoryGapRecord.scopeKey)) == %@ AND " +
                "\(#keyPath(HistoryGapRecord.upperInclusiveSequence)) >= %@ AND " +
                "\(#keyPath(HistoryGapRecord.lowerExclusiveSequence)) < %@",
            scope.uuidString, NSNumber(value: lower), NSNumber(value: upper)))
        guard gaps.isEmpty else {
            throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
        }
        return try insertHold(id: id, kind: .detail(firstSequence: lower, lastSequence: upper))
    }

    func releaseHold(_ id: UUID) throws {
        try activity.requireIdle()
        guard let row = try history.fetchOne(HistoryHoldRecord.self, keyPath: \.key, key: id.uuidString),
              row.scopeKey == scope.uuidString else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        context.delete(row)
        try history.saveRetention()
    }

    func retentionHolds() throws -> [HistoryRetentionHold] {
        guard !activity.closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        let generation = try history.scopeRecord().generationUUID()
        return try history.fetch(HistoryHoldRecord.self, predicate: NSPredicate(
            format: "\(#keyPath(HistoryHoldRecord.scopeKey)) == %@ AND \(#keyPath(HistoryHoldRecord.generationID)) == %@", scope.uuidString, generation.uuidString))
            .map { row in
                let kind: HistoryRetentionHold.Kind
                if row.kind == "state" {
                    kind = .state(checkpointID: try row.uuid(row.checkpointID))
                } else {
                    kind = .detail(firstSequence: row.lowerSequence?.int64Value ?? 0,
                                   lastSequence: row.upperSequence?.int64Value ?? 0)
                }
                return HistoryRetentionHold(id: try row.uuid(row.key), scope: scope,
                                            generation: generation, kind: kind)
            }
    }

    private func insertHold(id: UUID, kind: HistoryRetentionHold.Kind) throws -> HistoryRetentionHold {
        guard try history.fetchOne(HistoryHoldRecord.self, keyPath: \.key, key: id.uuidString) == nil else {
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
        let generation = try history.scopeRecord().generationUUID()
        let row = history.insert(HistoryHoldRecord.self)
        row.key = id.uuidString
        row.scopeKey = scope.uuidString
        row.generationID = generation.uuidString
        switch kind {
        case .state(let checkpointID):
            row.kind = "state"
            row.checkpointID = checkpointID.uuidString
        case .detail(let first, let last):
            row.kind = "detail"
            row.lowerSequence = NSNumber(value: first)
            row.upperSequence = NSNumber(value: last)
        }
        try history.saveRetention()
        return HistoryRetentionHold(id: id, scope: scope, generation: generation, kind: kind)
    }
}
