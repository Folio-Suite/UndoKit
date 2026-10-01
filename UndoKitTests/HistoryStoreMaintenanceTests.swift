// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

@MainActor final class HistoryStoreMaintenanceTests: XCTestCase {
    func testFailedCaptureReleasesMaintenanceAndPreservesCompletedCopy() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copiedURL = directory.appendingPathComponent("Copy.sqlite")
        let store = try await HistoryStore.open(
            at: directory.appendingPathComponent("History.sqlite"),
            workingIdentity: UUID(), mode: .create)
        let engine = try await store.openScope(UUID(), mode: .create,
            host: CounterHost(url: directory.appendingPathComponent("host.json")))

        do {
            try await store.withCoordinatedCopy(to: copiedURL) { _ in
                throw CocoaError(.fileWriteUnknown)
            }
            XCTFail("Failed capture returned successfully")
        } catch is CocoaError {
            XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path))
        }
        guard case .accepted = await engine.submit(HistoryCommand(
            fingerprint: Data("after capture".utf8), payload: payload(1))) else {
            XCTFail("Maintenance fence remained active after failed capture")
            return
        }
        try await store.close()
    }
}
