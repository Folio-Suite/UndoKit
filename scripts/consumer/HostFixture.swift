// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import UndoKit

#if CONSUMER_APP
import ConsumerDomain
import MachO
#endif

private struct StoredEffect: Codable {
    var memberID: String
    var undo: Data
    var redo: Data
}

private struct StoredOutcome: Codable {
    var effects: [StoredEffect]
}

private struct HostState: Codable {
    var value = ""
    var outcomes: [String: StoredOutcome] = [:]
    var appliedDeliveries = 0
    var appliedMembers = 0
}

/// Independent host with durable domain state and authoritative token receipts.
private actor DurableHost: HistoryHost {
    private let url: URL
    private var state: HostState

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(HostState.self, from: Data(contentsOf: url))
        } else {
            state = HostState()
        }
    }

    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        let key = Self.key(delivery.token)
        if let prior = state.outcomes[key] { return Self.outcome(prior) }

        var next = state
        var effects: [StoredEffect] = []
        for member in delivery.members {
            guard let target = String(data: member.payload.data, encoding: .utf8) else {
                return .failure(HistoryFailure(.hostProtocol, stage: .delivery, disposition: .usable))
            }
            let previous = next.value
            next.value = target
            effects.append(StoredEffect(memberID: member.id.uuidString,
                                        undo: Data(previous.utf8), redo: Data(target.utf8)))
        }
        next.appliedDeliveries += 1
        next.appliedMembers += delivery.members.count
        let receipt = StoredOutcome(effects: effects)
        next.outcomes[key] = receipt
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let bytes = try JSONEncoder().encode(next)
            try bytes.write(to: url, options: .atomic)
            state = next
            return Self.outcome(receipt)
        } catch {
            return .unresolved
        }
    }

    func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        guard let receipt = state.outcomes[Self.key(token)] else { return .rejected }
        return Self.outcome(receipt)
    }

    func snapshot() -> HostState { state }

    private static func key(_ token: HistoryToken) -> String {
        "\(token.scope.uuidString):\(token.generation.uuidString):\(token.sequence):\(token.command.uuidString)"
    }

    private static func outcome(_ stored: StoredOutcome) -> HistoryHostOutcome {
        .accepted(stored.effects.map {
            HistoryEffect(memberID: UUID(uuidString: $0.memberID)!,
                          undo: HistoryPayload(family: "consumer-state", data: $0.undo),
                          redo: HistoryPayload(family: "consumer-state", data: $0.redo))
        })
    }
}

private struct ConsumerReport: Codable {
    var route: String
    var platform: String
    var hostValue: String
    var groupMemberCount: Int
    var receiptCount: Int
    var appliedDeliveries: Int
    var appliedMembers: Int
    var reopenedCanUndo: Bool
    var reopenedCanRedo: Bool
    var bundledModelLoaded: Bool
    var sharedUndoKitTypeIdentity: Bool?
    var undoKitLoadedImages: [String]?
    var runtimeVersion: String
    var processArchitecture: String
}

@MainActor
private func runConsumerFixture(route: String) async throws -> ConsumerReport {
    let root: URL
    #if CONSUMER_APP
    root = try consumerEvidenceDirectory(route)
    #else
    root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UNDOkit_CONSUMER_ROOT"]!,
               isDirectory: true)
    #endif
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let storeURL = root.appendingPathComponent("History.sqlite")
    let host = try DurableHost(url: root.appendingPathComponent("HostState.json"))
    let workingIdentity = UUID(uuidString: "31000000-0000-4000-8000-000000000001")!
    let scope = UUID(uuidString: "31000000-0000-4000-8000-000000000002")!
    var engine = try await HistoryEngine.open(at: storeURL, scope: scope,
                                              workingIdentity: workingIdentity, mode: .create, host: host)

    let memberA = UUID(uuidString: "31000000-0000-4000-8000-000000000011")!
    let memberB = UUID(uuidString: "31000000-0000-4000-8000-000000000012")!
    let command = HistoryCommand(
        id: UUID(uuidString: "31000000-0000-4000-8000-000000000010")!,
        fingerprint: Data("two-member-command-v1".utf8),
        members: [
            HistoryMember(id: memberA, payload: HistoryPayload(family: "consumer-state", data: Data("alpha".utf8))),
            HistoryMember(id: memberB, payload: HistoryPayload(family: "consumer-state", data: Data("alpha-beta".utf8)))
        ])
    guard case .accepted = await engine.submit(command) else {
        throw FixtureError.assertion("grouped host Command was not accepted")
    }
    guard case .accepted = await engine.undo(expectedGeneration: engine.snapshot.generation) else {
        throw FixtureError.assertion("Undo was not accepted")
    }
    guard await host.snapshot().value.isEmpty else {
        throw FixtureError.assertion("Undo did not restore the original host value")
    }
    guard case .accepted = await engine.redo(expectedGeneration: engine.snapshot.generation) else {
        throw FixtureError.assertion("Redo was not accepted")
    }
    try await engine.close()

    let reopenedHost = try DurableHost(url: root.appendingPathComponent("HostState.json"))
    engine = try await HistoryEngine.open(at: storeURL, scope: scope,
                                          workingIdentity: workingIdentity, mode: .existing, host: reopenedHost)
    let snapshot = await reopenedHost.snapshot()
    let available = engine.snapshot
    let entries = try engine.historyPage(limit: 20)
    guard snapshot.value == "alpha-beta", snapshot.appliedDeliveries == 3,
          snapshot.appliedMembers == 6, snapshot.outcomes.count == 3,
          available.canUndo, !available.canRedo,
          entries.contains(where: { $0.memberCount == 2 }) else {
        throw FixtureError.assertion("reopen state, receipts, delivery count, or grouped history did not match")
    }
    try await engine.close()
    #if CONSUMER_APP
    let sharedTypeIdentity = consumerDomainHistoryStoreTypeIdentity() == ObjectIdentifier(HistoryStore.self)
    let loadedImages = (0..<_dyld_image_count()).compactMap { index -> String? in
        guard let name = _dyld_get_image_name(index) else { return nil }
        let path = String(cString: name)
        return path.contains("UndoKit.framework") || path.hasSuffix("libUndoKit.dylib") ? path : nil
    }
    guard sharedTypeIdentity else {
        throw FixtureError.assertion("app and domain framework resolved different UndoKit HistoryStore type identities")
    }
    guard loadedImages.count == 1 else {
        throw FixtureError.assertion("expected one loaded UndoKit runtime image, found \(loadedImages)")
    }
    #else
    let sharedTypeIdentity: Bool? = nil
    let loadedImages: [String]? = nil
    #endif
    return ConsumerReport(route: route, platform: consumerPlatform, hostValue: snapshot.value,
                          groupMemberCount: 2, receiptCount: snapshot.outcomes.count,
                          appliedDeliveries: snapshot.appliedDeliveries,
                          appliedMembers: snapshot.appliedMembers,
                          reopenedCanUndo: available.canUndo, reopenedCanRedo: available.canRedo,
                          bundledModelLoaded: true,
                          sharedUndoKitTypeIdentity: sharedTypeIdentity,
                          undoKitLoadedImages: loadedImages,
                          runtimeVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                          processArchitecture: processArchitecture)
}

private enum FixtureError: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { if case .assertion(let text) = self { return text }; return "fixture error" }
}

private var consumerPlatform: String {
    #if os(iOS)
    return "iOS Simulator"
    #elseif os(macOS)
    return "macOS"
    #else
    return "unknown"
    #endif
}

private var processArchitecture: String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}

#if CONSUMER_APP
import SwiftUI

@main
struct ConsumerApp: App {
    var body: some Scene {
        WindowGroup { Text("UndoKit consumer probe") }
    }
    init() {
        Task { @MainActor in
            do {
                let report = try await runConsumerFixture(route: "\(Self.route)")
                let url = try consumerEvidenceDirectory(Self.route).appendingPathComponent("ConsumerReport.json")
                try JSONEncoder().encode(report).write(to: url, options: .atomic)
                print("UNDOkit_CONSUMER_PASS \(url.path)")
                #if os(macOS)
                exit(EXIT_SUCCESS)
                #endif
            } catch {
                if let base = try? consumerEvidenceDirectory(Self.route) {
                    let url = base.appendingPathComponent("ConsumerFailure.txt")
                    try? Data(String(describing: error).utf8).write(to: url, options: .atomic)
                }
                print("UNDOkit_CONSUMER_FAIL \(error)")
                #if os(macOS)
                exit(EXIT_FAILURE)
                #endif
            }
        }
    }
    private static var route: String {
        #if NATIVE_FRAMEWORK
        return "native-framework"
        #else
        return "source-package"
        #endif
    }
}

@MainActor
private func consumerEvidenceDirectory(_ route: String) throws -> URL {
    let root: URL
    if let supplied = ProcessInfo.processInfo.environment["UNDOkit_CONSUMER_ROOT"] {
        root = URL(fileURLWithPath: supplied, isDirectory: true)
    } else {
        root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: true)
            .appendingPathComponent("UndoKitConsumerEvidence-\(route)", isDirectory: true)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
#else
@main
struct ConsumerCLI {
    @MainActor static func main() async throws {
        let report = try await runConsumerFixture(route: "source-package")
        let output = ProcessInfo.processInfo.environment["UNDOkit_CONSUMER_REPORT"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("UndoKitConsumerReport.json")
        try JSONEncoder().encode(report).write(to: output, options: .atomic)
        print("UndoKit consumer passed: \(output.path)")
    }
}
#endif
