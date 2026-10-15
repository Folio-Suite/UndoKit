// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit

/// Host-owned discovery evidence kept outside the document directories. A missing
/// known document is unavailable storage, never permission to create a new scope.
public struct NotesDocumentRegistry {
    public let root: URL
    private struct Record: Codable {
        let format: Int
        var documents: Set<String>
    }
    public init(root: URL) { self.root = root.standardizedFileURL }
    public func openMode(for directory: URL) throws -> NativeHistoryOpenMode {
        let directory = directory.standardizedFileURL
        guard directory.deletingLastPathComponent().path == root.path else {
            throw HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
        }
        let file = root.appendingPathComponent("KnownDocuments.json")
        var record: Record
        if FileManager.default.fileExists(atPath: file.path) {
            record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            guard record.format == 1 else {
                throw HistoryFailure(.compatibility, stage: .admission, disposition: .suspended)
            }
        } else {
            record = Record(format: 1, documents: [])
        }
        let name = directory.lastPathComponent
        if record.documents.contains(name) { return .existing }
        let hasEvidence = ["Note.json", "History.sqlite", "Draft.json"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        // Persist discovery before attempting creation. A partial/failed first creation
        // remains known and must be recovered rather than silently replaced next launch.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        record.documents.insert(name)
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        return hasEvidence ? .existing : .create
    }
}
