// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

// Generated Core Data extensions provide the typed fetch requests for this protocol.
protocol HistoryManagedRecord: NSManagedObject {
    static func fetchRequest() -> NSFetchRequest<Self>
}

// These internal class shells keep managed objects inside UndoKit. Xcode generates
// their properties from HistoryV1 using Category/Extension code generation.

@objc(HistoryScopeRecord)
final class HistoryScopeRecord: NSManagedObject, HistoryManagedRecord {

    func generationUUID() throws -> UUID { try uuid(generationID) }
}

@objc(HistoryTransactionRecord)
final class HistoryTransactionRecord: NSManagedObject, HistoryManagedRecord {
}

@objc(HistoryMemberRecord)
final class HistoryMemberRecord: NSManagedObject, HistoryManagedRecord {
}

@objc(HistoryGroupRecord)
final class HistoryGroupRecord: NSManagedObject, HistoryManagedRecord {
}

@objc(HistoryActionRecord)
final class HistoryActionRecord: NSManagedObject, HistoryManagedRecord {
}

@objc(HistoryCheckpointRecord)
final class HistoryCheckpointRecord: NSManagedObject, HistoryManagedRecord {
}

@objc(HistoryStoreRecord)
final class HistoryStoreRecord: NSManagedObject, HistoryManagedRecord {
}

@objc(HistoryGapRecord)
final class HistoryGapRecord: NSManagedObject, HistoryManagedRecord {
}

@objc(HistoryHoldRecord)
final class HistoryHoldRecord: NSManagedObject, HistoryManagedRecord {
}

@objc(HistoryResourceRecord)
final class HistoryResourceRecord: NSManagedObject, HistoryManagedRecord {
}

@objc(HistoryRetiredCommandRecord)
final class HistoryRetiredCommandRecord: NSManagedObject, HistoryManagedRecord {
}

@objc(HistoryCleanupRecord)
final class HistoryCleanupRecord: NSManagedObject, HistoryManagedRecord {
}

extension NSManagedObject {
    func uuid(_ raw: String?) throws -> UUID {
        guard let raw, let value = UUID(uuidString: raw) else {
            throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
        }
        return value
    }
}
