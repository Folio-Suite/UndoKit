#!/bin/bash
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/undokit-consumer.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

mkdir -p "$temporary_root/Sources/Consumer"
cat > "$temporary_root/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UndoKitConsumer",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "UndoKit", path: "$repository_root")],
    targets: [.executableTarget(name: "Consumer", dependencies: [.product(name: "UndoKit", package: "UndoKit")])]
)
MANIFEST

cat > "$temporary_root/Sources/Consumer/main.swift" <<'SWIFT'
import Foundation
import UndoKit

@main
struct Consumer {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UndoKit-consumer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("History.sqlite")
        let workingIdentity = UUID()
        let store = try await HistoryStore.open(
            at: storeURL,
            workingIdentity: workingIdentity,
            mode: .create
        )
        try await store.close()

        let reopenedStore = try await HistoryStore.open(
            at: storeURL,
            workingIdentity: workingIdentity,
            mode: .existing
        )
        try await reopenedStore.close()
        print("UndoKit package consumer opened and reopened a store")
    }
}
SWIFT

swift run --package-path "$temporary_root" Consumer
