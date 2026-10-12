// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
@testable import UndoKit
import XCTest

@MainActor private final class ReentrantMaintenanceHost: HistoryHost {
    weak var store: HistoryStore?
    let copyURL: URL
    var copyFailure: HistoryFailure?
    var closeFailure: HistoryFailure?

    init(copyURL: URL) { self.copyURL = copyURL }

    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        do {
            try await store?.copy(to: copyURL)
        } catch let failure as HistoryFailure {
            copyFailure = failure
        } catch {
            return .unresolved
        }
        do {
            try await store?.close()
        } catch let failure as HistoryFailure {
            closeFailure = failure
        } catch {
            return .unresolved
        }
        return .rejected
    }

    func outcome(for token: HistoryToken) async -> HistoryHostOutcome { .rejected }
}

@MainActor private final class NestedDeliveryHost: HistoryHost {
    var nested: HistoryEngine?

    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        if let nested {
            _ = await nested.submit(HistoryCommand(fingerprint: Data("nested".utf8), payload: payload(2)))
        }
        return .rejected
    }

    func outcome(for token: HistoryToken) async -> HistoryHostOutcome { .rejected }
}

extension HistoryStoreLifecycleTests {
    func testHostCallbackCannotWaitForItsOwnStoreCopyOrClose() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
                                                workingIdentity: UUID(), mode: .create)
        let host = ReentrantMaintenanceHost(copyURL: directory.appendingPathComponent("Copy.sqlite"))
        host.store = store
        let engine = try await store.openScope(UUID(), mode: .create, host: host)
        let result = await engine.submit(HistoryCommand(fingerprint: Data("rejected".utf8), payload: payload(1)))
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(host.copyFailure?.cause, .busy)
        XCTAssertEqual(host.closeFailure?.cause, .busy)
        try await store.close()
    }

    func testNestedHostDeliveryCannotCopyOrCloseOuterStore() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outerStore = try await HistoryStore.open(at: directory.appendingPathComponent("Outer.sqlite"),
                                                     workingIdentity: UUID(), mode: .create)
        let innerStore = try await HistoryStore.open(at: directory.appendingPathComponent("Inner.sqlite"),
                                                     workingIdentity: UUID(), mode: .create)
        let outerHost = NestedDeliveryHost()
        let innerHost = ReentrantMaintenanceHost(copyURL: directory.appendingPathComponent("Copy.sqlite"))
        innerHost.store = outerStore
        let outer = try await outerStore.openScope(UUID(), mode: .create, host: outerHost)
        outerHost.nested = try await innerStore.openScope(UUID(), mode: .create, host: innerHost)
        let result = await outer.submit(HistoryCommand(
            fingerprint: Data("outer".utf8), payload: payload(1)))
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(innerHost.copyFailure?.cause, .busy)
        XCTAssertEqual(innerHost.closeFailure?.cause, .busy)
        try await outerStore.close()
        try await innerStore.close()
    }
}
