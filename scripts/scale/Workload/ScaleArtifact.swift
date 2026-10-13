// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit

/// Inventories the actual executable and resources at the command/device boundary.
/// Hash every file without excluding signing or installation-mutated material.
public enum ScaleArtifact {
    public static func inventory(directory: URL) throws -> [String: String] {
        guard let files = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
            throw ScaleFailure.assertion("Cannot enumerate installed artifact")
        }
        let prefix = directory.standardizedFileURL.path + "/"
        var result: [String: String] = [:]
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw ScaleFailure.assertion("Artifact path escaped root") }
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            var digest = SHA256()
            while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                digest.update(data: bytes)
            }
            result[String(path.dropFirst(prefix.count))] = digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard !result.isEmpty else { throw ScaleFailure.assertion("Installed artifact inventory is empty") }
        return result
    }
}
