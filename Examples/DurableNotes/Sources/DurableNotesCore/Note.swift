// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit

public struct Note: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    public init(title: String = "", body: String = "") { self.title = title; self.body = body }
}

public struct NotesReadout: Sendable {
    public let note: Note
    public let receiptCount: Int
    public let applicationCount: Int
}

struct NoteChange: Codable, Sendable {
    enum Field: String, Codable, Sendable { case title, body }
    let field: Field
    let expected: String
    let replacement: String

    func payload() throws -> HistoryPayload {
        HistoryPayload(family: "durable-notes.change", version: 1, data: try JSONEncoder().encode(self))
    }

    static func decode(_ payload: HistoryPayload) throws -> Self {
        guard payload.family == "durable-notes.change", payload.version == 1 else {
            throw HistoryFailure(.compatibility, stage: .delivery, disposition: .suspended)
        }
        return try JSONDecoder().decode(Self.self, from: payload.data)
    }
}
