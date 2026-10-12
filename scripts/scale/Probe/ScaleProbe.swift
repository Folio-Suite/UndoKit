// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import Foundation
import Darwin
import ScaleWorkload

@main struct ScaleProbe {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("SCALE FAILED: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
    @MainActor private static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4 else { throw ScaleFailure.assertion("Usage: ScaleProbe create|reopen directory report [groups seed]") }
        let directory = URL(fileURLWithPath: arguments[2])
        let output = URL(fileURLWithPath: arguments[3])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if arguments[1] == "create" {
            guard arguments.count == 6, let groups = Int(arguments[4]), let seed = Int(arguments[5]) else {
                throw ScaleFailure.assertion("Creation requires integer groups and seed")
            }
            let report = try await ScaleWorkload.create(directory: directory, groups: groups, seed: seed) { phase in
                print("SCALE phase=\(phase)")
                try? Data(phase.utf8).write(to: directory.appendingPathComponent("Phase.txt"), options: .atomic)
            }
            try encoder.encode(report).write(to: output, options: .atomic)
        } else if arguments[1] == "reopen" {
            let report = try await ScaleWorkload.reopen(directory: directory)
            try encoder.encode(report).write(to: output, options: .atomic)
        } else if arguments[1] == "artifact" {
            try encoder.encode(ScaleArtifact.inventory(directory: directory)).write(to: output, options: .atomic)
        } else if arguments[1] == "receipt-write-failure" || arguments[1] == "receipt-write-readback" {
            let report = try await ScaleWorkload.receiptWriteFailure(directory: directory,
                readback: arguments[1] == "receipt-write-readback")
            try encoder.encode(report).write(to: output, options: .atomic)
        } else { throw ScaleFailure.assertion("Unknown scale operation") }
    }
}
