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
              first.string("scopeKey") == scope.uuidString,
              last.string("scopeKey") == scope.uuidString,
              first.int64("sequence") <= last.int64("sequence") else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        let lower = first.int64("sequence")
        let upper = last.int64("sequence")
        let gaps = try history.fetch("HistoryGapRecord", predicate: NSPredicate(
            format: "scopeKey == %@ AND upperInclusiveSequence >= %@ AND lowerExclusiveSequence < %@",
            scope.uuidString, NSNumber(value: lower), NSNumber(value: upper)))
        guard gaps.isEmpty else {
            throw HistoryFailure(.compatibility, stage: .admission, disposition: .usable)
        }
        return try insertHold(id: id, kind: .detail(firstSequence: lower, lastSequence: upper))
    }

    func releaseHold(_ id: UUID) throws {
        try activity.requireIdle()
        guard let row = try history.fetchOne("HistoryHoldRecord", key: id.uuidString),
              row.string("scopeKey") == scope.uuidString else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        context.delete(row)
        try history.saveRetention()
    }

    func retentionHolds() throws -> [HistoryRetentionHold] {
        guard !activity.closed else { throw HistoryFailure(.busy, stage: .admission, disposition: .usable) }
        let generation = try history.scopeRecord().uuid("generationID")
        return try history.fetch("HistoryHoldRecord", predicate: NSPredicate(
            format: "scopeKey == %@ AND generationID == %@", scope.uuidString, generation.uuidString))
            .map { row in
                let kind: HistoryRetentionHold.Kind
                if row.string("kind") == "state" {
                    kind = .state(checkpointID: try row.uuid("checkpointID"))
                } else {
                    kind = .detail(firstSequence: row.int64("lowerSequence"),
                                   lastSequence: row.int64("upperSequence"))
                }
                return HistoryRetentionHold(id: try row.uuid("key"), scope: scope,
                                            generation: generation, kind: kind)
            }
    }

    private func insertHold(id: UUID, kind: HistoryRetentionHold.Kind) throws -> HistoryRetentionHold {
        guard try history.fetchOne("HistoryHoldRecord", key: id.uuidString) == nil else {
            throw HistoryFailure(.identityConflict, stage: .admission, disposition: .usable)
        }
        let generation = try history.scopeRecord().uuid("generationID")
        let row = history.insert("HistoryHoldRecord")
        row.setValue(id.uuidString, forKey: "key")
        row.setValue(scope.uuidString, forKey: "scopeKey")
        row.setValue(generation.uuidString, forKey: "generationID")
        switch kind {
        case .state(let checkpointID):
            row.setValue("state", forKey: "kind")
            row.setValue(checkpointID.uuidString, forKey: "checkpointID")
        case .detail(let first, let last):
            row.setValue("detail", forKey: "kind")
            row.setValue(first, forKey: "lowerSequence")
            row.setValue(last, forKey: "upperSequence")
        }
        try history.saveRetention()
        return HistoryRetentionHold(id: id, scope: scope, generation: generation, kind: kind)
    }
}
