// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import CryptoKit
import Foundation

extension HistoryScopeStorage {
    enum CompensationPayloadRole { case undo, redo }

    private func validatedPayload(family: String?, version: Int64, data: Data?,
                                  storedDigest: Data?) throws -> HistoryPayload {
        guard let family, let data else {
            throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
        }
        let payload = HistoryPayload(family: family, version: Int(version), data: data)
        guard storedDigest == digest(payload) else {
            throw HistoryFailure(.storage, stage: .reconciliation, disposition: .suspended)
        }
        return payload
    }

    func payload(on row: HistoryMemberRecord, role: CompensationPayloadRole) throws -> HistoryPayload {
        switch role {
        case .undo:
            return try validatedPayload(family: row.undoFamily,
                version: row.undoVersion?.int64Value ?? 0, data: row.undoPayload,
                storedDigest: row.undoDigest)
        case .redo:
            return try validatedPayload(family: row.redoFamily,
                version: row.redoVersion?.int64Value ?? 0, data: row.redoPayload,
                storedDigest: row.redoDigest)
        }
    }

    func payload(on row: HistoryActionRecord, role: CompensationPayloadRole) throws -> HistoryPayload {
        switch role {
        case .undo:
            return try validatedPayload(family: row.undoFamily,
                version: row.undoVersion, data: row.undoPayload, storedDigest: row.undoDigest)
        case .redo:
            return try validatedPayload(family: row.redoFamily,
                version: row.redoVersion, data: row.redoPayload, storedDigest: row.redoDigest)
        }
    }

    func presentationPayload(on row: HistoryGroupRecord) throws -> HistoryPayload {
        return try validatedPayload(family: row.presentationFamily,
            version: row.presentationVersion?.int64Value ?? 0, data: row.presentationPayload,
            storedDigest: row.presentationDigest)
    }

    func putPresentation(_ payload: HistoryPayload, on row: HistoryTransactionRecord) {
        row.presentationFamily = payload.family
        row.presentationVersion = NSNumber(value: payload.version)
        row.presentationPayload = payload.data
        row.presentationDigest = digest(payload)
    }

    func put(_ payload: HistoryPayload, on row: HistoryMemberRecord, role: CompensationPayloadRole) {
        switch role {
        case .undo:
            row.undoFamily = payload.family
            row.undoVersion = NSNumber(value: payload.version)
            row.undoPayload = payload.data
            row.undoDigest = digest(payload)
        case .redo:
            row.redoFamily = payload.family
            row.redoVersion = NSNumber(value: payload.version)
            row.redoPayload = payload.data
            row.redoDigest = digest(payload)
        }
    }

    func put(_ payload: HistoryPayload, on row: HistoryActionRecord, role: CompensationPayloadRole) {
        switch role {
        case .undo:
            row.undoFamily = payload.family
            row.undoVersion = Int64(payload.version)
            row.undoPayload = payload.data
            row.undoDigest = digest(payload)
        case .redo:
            row.redoFamily = payload.family
            row.redoVersion = Int64(payload.version)
            row.redoPayload = payload.data
            row.redoDigest = digest(payload)
        }
    }

    func digest(_ payload: HistoryPayload) -> Data {
        var input = Data(payload.family.utf8)
        input.append(0)
        input.append(contentsOf: String(payload.version).utf8)
        input.append(0)
        input.append(payload.data)
        return Data(SHA256.hash(data: input))
    }

}
