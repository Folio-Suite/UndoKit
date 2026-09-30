// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

private struct CodecFixture: Codable, Equatable {
    let title: String
    let count: Int
}

private final class CodableBox: Codable {
    let text: String
    init(text: String) { self.text = text }
}

@MainActor private final class ReentrantHistoryHost: HistoryHost {
    weak var engine: HistoryEngine?
    var nestedResult: HistoryResult?

    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        nestedResult = await engine?.submit(HistoryCommand(fingerprint: Data("nested".utf8),
                                                           payload: payload(99)))
        return .rejected
    }

    func outcome(for token: HistoryToken) async -> HistoryHostOutcome { .rejected }
}

@MainActor private final class CountingOpaqueHost: HistoryHost {
    private(set) var deliveryCount = 0
    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        deliveryCount += 1
        return .rejected
    }
    func outcome(for token: HistoryToken) async -> HistoryHostOutcome { .unresolved }
}

private actor MixedFamilyReceiptStore {
    private var receipts: [UUID: HistoryHostOutcome] = [:]

    func deliver(_ delivery: HistoryDelivery) -> HistoryHostOutcome {
        let accepted = HistoryHostOutcome.accepted(delivery.members.map { member in
            HistoryEffect(memberID: member.id,
                          undo: HistoryPayload(family: member.payload.family, data: Data("undo".utf8)),
                          redo: HistoryPayload(family: member.payload.family, data: Data("redo".utf8)))
        })
        receipts[delivery.token.command] = accepted
        return .unresolved
    }

    func outcome(for token: HistoryToken) -> HistoryHostOutcome {
        receipts[token.command] ?? .unresolved
    }
}

@MainActor final class HistoryCodecTests: XCTestCase {
    func testExplicitCodableFormatsAndCustomCodecRoundTrip() throws {
        let value = CodecFixture(title: "A Folio", count: 7)
        let codecs = [
            HistoryCodec<CodecFixture>.json(),
            HistoryCodec<CodecFixture>.xmlPropertyList(),
            HistoryCodec<CodecFixture>.binaryPropertyList(),
            HistoryCodec<CodecFixture>(identifier: "fixture.lines.v1", configuration: Data("utf8".utf8),
                                       encode: { Data("\($0.title)|\($0.count)".utf8) },
                                       decode: { data in
                                           let text = String(bytes: data, encoding: .utf8) ?? ""
                                           let fields = text.split(separator: "|")
                                           guard fields.count == 2, let count = Int(fields[1]) else {
                                               throw CocoaError(.coderReadCorrupt)
                                           }
                                           return CodecFixture(title: String(fields[0]), count: count)
                                       }),
        ]

        for codec in codecs {
            XCTAssertFalse(codec.identifier.isEmpty)
            XCTAssertEqual(try codec.decode(codec.encode(value)), value)
        }
        XCTAssertEqual(codecs[3].configuration, Data("utf8".utf8))

        let referenceCodec = HistoryCodec<CodableBox>.json()
        XCTAssertEqual(try referenceCodec.decode(referenceCodec.encode(CodableBox(text: "class"))).text,
                       "class")
    }

    func testCallbackReentryIntoSameEngineIsRejectedWithoutWaitingOnItsQueue() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = ReentrantHistoryHost()
        let engine = try await HistoryEngine.open(at: directory.appendingPathComponent("History.sqlite"),
                                                   scope: UUID(), workingIdentity: UUID(), mode: .create,
                                                   host: host)
        host.engine = engine
        let outer = await engine.submit(HistoryCommand(fingerprint: Data("outer".utf8), payload: payload(1)))
        XCTAssertEqual(outer, .rejected)
        guard case .failure(let failure)? = host.nestedResult else {
            XCTFail("Same-engine nested request was not rejected")
            return
        }
        XCTAssertEqual(failure.cause, .busy)
        XCTAssertEqual(failure.stage, .admission)
        try await engine.close()
    }

    func testMixedFamilyGroupRefusesBeforeAnyFamilyReceivesIt() async throws {
        let first = CountingOpaqueHost()
        let second = CountingOpaqueHost()
        let registry = try HistoryHostRegistry(registrations: [("first", first), ("second", second)])
        let delivery = HistoryDelivery(
            token: HistoryToken(scope: UUID(), generation: UUID(), sequence: 1, command: UUID()),
            kind: .command,
            members: [HistoryMember(payload: HistoryPayload(family: "first", data: Data([1]))),
                      HistoryMember(payload: HistoryPayload(family: "second", data: Data([2])))],
            restorationOrigin: nil
        )

        guard case .failure(let failure) = await registry.deliver(delivery) else {
            XCTFail("Mixed-family delivery without an atomic executor was not refused")
            return
        }
        XCTAssertEqual(failure.cause, .invalidInput)
        XCTAssertEqual(first.deliveryCount, 0)
        XCTAssertEqual(second.deliveryCount, 0)
    }

    func testMixedFamilyAcceptedReceiptReconcilesAfterEngineReopen() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipts = MixedFamilyReceiptStore()
        let storeURL = directory.appendingPathComponent("History.sqlite")
        let scope = UUID()
        let workingID = UUID()
        let firstRegistry = try HistoryHostRegistry(
            registrations: [],
            atomicGroupExecutor: { await receipts.deliver($0) },
            atomicOutcomeLookup: { await receipts.outcome(for: $0) }
        )
        let first = try await HistoryEngine.open(at: storeURL, scope: scope, workingIdentity: workingID,
                                                 mode: .create, host: firstRegistry)
        let command = HistoryCommand(fingerprint: Data("atomic mixed family".utf8), members: [
            HistoryMember(payload: HistoryPayload(family: "text.replace", data: Data("new".utf8))),
            HistoryMember(payload: HistoryPayload(family: "unit.move", data: Data("destination".utf8)))
        ])
        guard case .failure(let failure) = await first.submit(command) else {
            XCTFail("Lost mixed-group response did not suspend history")
            return
        }
        XCTAssertEqual(failure.disposition, .suspended)
        try await first.close()

        let reopenedRegistry = try HistoryHostRegistry(
            registrations: [],
            atomicGroupExecutor: { await receipts.deliver($0) },
            atomicOutcomeLookup: { await receipts.outcome(for: $0) }
        )
        let reopened = try await HistoryEngine.open(at: storeURL, scope: scope, workingIdentity: workingID,
                                                    mode: .existing, host: reopenedRegistry)
        XCTAssertFalse(reopened.snapshot.isSuspended)
        XCTAssertTrue(reopened.snapshot.canUndo)
        try await reopened.close()
    }

}
