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
    /// Delivery callbacks since this domain host was acquired; outcome lookup does not deliver.
    public let deliveryCount: Int
}

public struct NoteChange: Codable, Sendable {
    public enum Field: String, Codable, Sendable { case title, body }
    public let field: Field
    public let expected: String
    public let replacement: String

    public init(field: Field, expected: String, replacement: String) {
        self.field = field; self.expected = expected; self.replacement = replacement
    }
}
