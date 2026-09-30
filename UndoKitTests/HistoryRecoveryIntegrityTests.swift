// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation
@testable import UndoKit
import XCTest

@MainActor final class HistoryRecoveryIntegrityTests: XCTestCase {
    func testUnknownPresentationCodecUsesGenericNativeLabel() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.cd"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host)
        _ = await engine.submit(HistoryCommand(fingerprint: Data("one".utf8), payload: payload(1),
            presentation: HistoryPayload(family: "future.codec", data: Data([1]))))
        let names = try engine.nativeActionNames { _ in throw CocoaError(.coderReadCorrupt) }
        XCTAssertEqual(names.names.undo, "")
        XCTAssertEqual(names.snapshot, engine.snapshot)
        try await engine.close()
    }

    func testMissingInteriorTransitionRefusesBothDirections() async throws {
        for forward in [false, true] {
            let directory = try testDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
            let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.cd"),
                scope: UUID(), workingIdentity: UUID(), mode: .create, host: host)
            _ = await engine.submit(HistoryCommand(fingerprint: Data("one".utf8), payload: payload(1)))
            let checkpoint = try engine.createCheckpoint(name: "one", state: payload(1))
            _ = await engine.submit(HistoryCommand(fingerprint: Data("two".utf8), payload: payload(2)))
            _ = await engine.submit(HistoryCommand(fingerprint: Data("three".utf8), payload: payload(3)))
            let entries = try engine.historyPage(limit: 10)
            let target = forward ? entries[2].groupID : entries[0].groupID
            let plan = try engine.beginRecoveryPlan(from: forward ? .checkpoint(checkpoint.id) : .current,
                to: .group(target), using: .acceptedEffects)
            // Simulate an incomplete external redaction after a plan was issued.
            // The fixture mutation deliberately bypasses UndoKit's pruning API.
            let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryGroupRecord")
            request.predicate = NSPredicate(format: "key == %@", entries[1].groupID.uuidString)
            engine.context.delete(try XCTUnwrap(engine.context.fetch(request).first))
            try engine.context.save()
            XCTAssertThrowsError(try engine.recoveryPage(plan, limit: 1))
            XCTAssertEqual(host.value, 3)
            engine.releaseRecoveryPlan(plan)
            try await engine.close()
        }
    }
    func testPersistedChainAllowsCheckpointAndRejectedSequenceHoles() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let url = directory.appendingPathComponent("History.cd")
        let scope = UUID(), workingID = UUID()
        var engine = try await HistoryEngine.open(at: url, scope: scope,
            workingIdentity: workingID, mode: .create, host: host)
        _ = await engine.submit(HistoryCommand(fingerprint: Data("one".utf8), payload: payload(1)))
        let checkpoint = try engine.createCheckpoint(name: "one", state: payload(1))
        host.rejectNext = true
        _ = await engine.submit(HistoryCommand(fingerprint: Data("reject".utf8), payload: payload(99)))
        _ = await engine.submit(HistoryCommand(fingerprint: Data("two".utf8), payload: payload(2)))
        let entries = try engine.historyPage(limit: 10)
        try await engine.close()
        engine = try await HistoryEngine.open(at: url, scope: scope,
            workingIdentity: workingID, mode: .existing, host: host)
        let forward = try engine.beginRecoveryPlan(from: .checkpoint(checkpoint.id),
            to: .group(entries[1].groupID), using: .acceptedEffects)
        XCTAssertEqual(try engine.recoveryPage(forward, limit: 1).steps.count, 1)
        engine.releaseRecoveryPlan(forward)
        let reverse = try engine.beginRecoveryPlan(to: .group(entries[0].groupID), using: .acceptedEffects)
        XCTAssertEqual(try engine.recoveryPage(reverse, limit: 1).steps.count, 1)
        engine.releaseRecoveryPlan(reverse)
        try await engine.close()
    }

    func testMissingLatestTransitionDoesNotSilentlyChangeCurrentBaseline() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try CounterHost(url: directory.appendingPathComponent("host.json"))
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.cd"),
            scope: UUID(), workingIdentity: UUID(), mode: .create, host: host)
        for value in 1...2 {
            _ = await engine.submit(HistoryCommand(fingerprint: Data("set \(value)".utf8), payload: payload(value)))
        }
        let entries = try engine.historyPage(limit: 10)
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryGroupRecord")
        request.predicate = NSPredicate(format: "key == %@", entries[1].groupID.uuidString)
        engine.context.delete(try XCTUnwrap(engine.context.fetch(request).first))
        try engine.context.save()
        XCTAssertThrowsError(try engine.readIdentity())
        let plan = try engine.beginRecoveryPlan(to: .group(entries[0].groupID), using: .acceptedEffects)
        XCTAssertThrowsError(try engine.recoveryPage(plan, limit: 1))
        engine.releaseRecoveryPlan(plan)
        try await engine.close()
    }

}
