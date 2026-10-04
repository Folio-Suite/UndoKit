// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

// These classes are internal to UndoKit. Reference attributes remain optional in Swift
// so malformed persisted rows can still reach the existing validation paths.

@objc(HistoryScopeRecord)
final class HistoryScopeRecord: NSManagedObject {
    @NSManaged var key: String?
    @NSManaged var workingID: String?
    @NSManaged var generationID: String?
    @NSManaged var nextSequence: Int64
    @NSManaged var committedVersion: Int64
    @NSManaged var suspended: Bool
    @NSManaged var latestAcceptedSequence: Int64
    @NSManaged var recordingEnabled: Bool
    @NSManaged var undoFloorSequence: Int64
    @NSManaged var currentBaselineSequence: Int64
    @NSManaged var requiresGenerationBinding: Bool
    @NSManaged var offStartSequence: Int64

    func generationUUID() throws -> UUID { try uuid(generationID) }
}

@objc(HistoryTransactionRecord)
final class HistoryTransactionRecord: NSManagedObject {
    @NSManaged var key: String?
    @NSManaged var scopeKey: String?
    @NSManaged var commandID: String?
    @NSManaged var fingerprint: Data?
    @NSManaged var generationID: String?
    @NSManaged var sequence: Int64
    @NSManaged var stage: String?
    @NSManaged var failureCause: String?
    @NSManaged var failureStage: String?
    @NSManaged var failureDescription: String?
    @NSManaged var kind: String?
    @NSManaged var groupID: String?
    @NSManaged var targetGroupID: String?
    @NSManaged var restorationOrigin: String?
    @NSManaged var memberCount: Int64
    @NSManaged var recordedAt: Date?
    @NSManaged var recordsAction: Bool
    @NSManaged var presentationFamily: String?
    @NSManaged var presentationVersion: NSNumber?
    @NSManaged var presentationPayload: Data?
    @NSManaged var presentationDigest: Data?
    @NSManaged var members: Set<HistoryMemberRecord>?
}

@objc(HistoryMemberRecord)
final class HistoryMemberRecord: NSManagedObject {
    @NSManaged var key: String?
    @NSManaged var ordinal: Int64
    @NSManaged var memberID: String?
    @NSManaged var family: String?
    @NSManaged var version: Int64
    @NSManaged var payload: Data?
    @NSManaged var payloadDigest: Data?
    @NSManaged var undoFamily: String?
    @NSManaged var undoVersion: NSNumber?
    @NSManaged var undoPayload: Data?
    @NSManaged var undoDigest: Data?
    @NSManaged var redoFamily: String?
    @NSManaged var redoVersion: NSNumber?
    @NSManaged var redoPayload: Data?
    @NSManaged var redoDigest: Data?
    @NSManaged var transaction: HistoryTransactionRecord?
}

@objc(HistoryGroupRecord)
final class HistoryGroupRecord: NSManagedObject {
    @NSManaged var key: String?
    @NSManaged var scopeKey: String?
    @NSManaged var sequence: Int64
    @NSManaged var kind: String?
    @NSManaged var state: String?
    @NSManaged var sourceGroupID: String?
    @NSManaged var compensationGroupID: String?
    @NSManaged var restorationOrigin: String?
    @NSManaged var memberCount: Int64
    @NSManaged var recordedAt: Date?
    @NSManaged var presentationFamily: String?
    @NSManaged var presentationVersion: NSNumber?
    @NSManaged var presentationPayload: Data?
    @NSManaged var presentationDigest: Data?
    @NSManaged var previousAcceptedSequence: Int64
    @NSManaged var actions: Set<HistoryActionRecord>?
}

@objc(HistoryActionRecord)
final class HistoryActionRecord: NSManagedObject {
    @NSManaged var key: String?
    @NSManaged var transactionKey: String?
    @NSManaged var memberID: String?
    @NSManaged var ordinal: Int64
    @NSManaged var kind: String?
    @NSManaged var undoFamily: String?
    @NSManaged var undoVersion: Int64
    @NSManaged var undoPayload: Data?
    @NSManaged var undoDigest: Data?
    @NSManaged var redoFamily: String?
    @NSManaged var redoVersion: Int64
    @NSManaged var redoPayload: Data?
    @NSManaged var redoDigest: Data?
    @NSManaged var group: HistoryGroupRecord?
}

@objc(HistoryCheckpointRecord)
final class HistoryCheckpointRecord: NSManagedObject {
    @NSManaged var key: String?
    @NSManaged var scopeKey: String?
    @NSManaged var name: String?
    @NSManaged var sequence: Int64
    @NSManaged var recordedAt: Date?
    @NSManaged var family: String?
    @NSManaged var version: Int64
    @NSManaged var state: Data?
    @NSManaged var stateDigest: Data?
    @NSManaged var latestAcceptedSequence: Int64
}

@objc(HistoryStoreRecord)
final class HistoryStoreRecord: NSManagedObject {
    @NSManaged var key: String?
    @NSManaged var workingID: String?
    @NSManaged var storeID: String?
}

@objc(HistoryGapRecord)
final class HistoryGapRecord: NSManagedObject {
    @NSManaged var key: String?
    @NSManaged var scopeKey: String?
    @NSManaged var generationID: String?
    @NSManaged var lowerExclusiveSequence: Int64
    @NSManaged var upperInclusiveSequence: Int64
}

@objc(HistoryHoldRecord)
final class HistoryHoldRecord: NSManagedObject {
    @NSManaged var key: String?
    @NSManaged var scopeKey: String?
    @NSManaged var generationID: String?
    @NSManaged var kind: String?
    @NSManaged var checkpointID: String?
    @NSManaged var lowerSequence: NSNumber?
    @NSManaged var upperSequence: NSNumber?
}

@objc(HistoryResourceRecord)
final class HistoryResourceRecord: NSManagedObject {
    @NSManaged var key: String?
    @NSManaged var storeID: String?
    @NSManaged var objectKey: String?
    @NSManaged var versionKey: String?
    @NSManaged var ownerType: String?
    @NSManaged var ownerKey: String?
}

@objc(HistoryRetiredCommandRecord)
final class HistoryRetiredCommandRecord: NSManagedObject {
    @NSManaged var key: String?
    @NSManaged var fingerprint: Data?
    @NSManaged var generationID: String?
    @NSManaged var sequence: Int64
    @NSManaged var groupID: String?
    @NSManaged var commandID: String?
    @NSManaged var scopeKey: String?
}

@objc(HistoryCleanupRecord)
final class HistoryCleanupRecord: NSManagedObject {
    @NSManaged var key: String?
}

extension NSManagedObject {
    func uuid(_ raw: String?) throws -> UUID {
        guard let raw, let value = UUID(uuidString: raw) else {
            throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
        }
        return value
    }
}
