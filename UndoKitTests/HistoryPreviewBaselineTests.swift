// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation
import UndoKit
import XCTest

private struct PreviewBaselineRecipe: Decodable {
    struct Command: Decodable {
        let id: UUID
        let memberIDs: [UUID]
        let values: [Int]
    }
    let workingIdentity: UUID
    let scopeIdentity: UUID
    let retentionStoreIdentity: UUID
    let checkpointIdentity: UUID
    let codecFamily: String
    let codecVersion: Int
    let resourceFile: String
    let resourceObjectKey: String
    let resourceVersionKey: String
    let commands: [Command]
    let expectedHistorySequences: [Int64]
    let expectedHistoryKinds: [String]
    let expectedCheckpointValue: Int
    let expectedFinalHostValue: Int

    func payload(_ value: Int) -> HistoryPayload {
        HistoryPayload(family: codecFamily, version: codecVersion, data: Data(String(value).utf8))
    }

    var resource: HistoryObjectReference {
        HistoryObjectReference(storeID: retentionStoreIdentity, objectKey: resourceObjectKey,
                               versionKey: resourceVersionKey)
    }
}

/// Durable fixture host: effects and receipts share one atomic JSON replacement.
/// Canonical decimal codecs and the named resource are required for interpretation.
@MainActor private final class PreviewBaselineHost: HistoryHost {
    private struct Effect: Codable {
        let memberID: UUID
        let undo: Int
        let redo: Int
    }
    private struct State: Codable {
        var value = 0
        var receipts: [String: [Effect]] = [:]
    }
    private var state: State
    private let recipe: PreviewBaselineRecipe
    private let stateURL: URL
    private let resourceURL: URL
    var value: Int { state.value }
    var receiptCount: Int { state.receipts.count }

    init(recipe: PreviewBaselineRecipe, directory: URL) throws {
        self.recipe = recipe
        stateURL = directory.appendingPathComponent("host-state.json")
        resourceURL = directory.appendingPathComponent(recipe.resourceFile)
        state = FileManager.default.fileExists(atPath: stateURL.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)) : State()
    }

    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        if let prior = state.receipts[delivery.token.command.uuidString] { return outcome(prior) }
        guard FileManager.default.fileExists(atPath: resourceURL.path) else {
            return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable))
        }
        var next = state
        var effects: [Effect] = []
        for member in delivery.members {
            guard member.payload.family == recipe.codecFamily,
                  member.payload.version == recipe.codecVersion,
                  let text = String(data: member.payload.data, encoding: .utf8),
                  let value = Int(text), String(value) == text else {
                return .failure(HistoryFailure(.compatibility, stage: .delivery, disposition: .usable))
            }
            effects.append(Effect(memberID: member.id, undo: next.value, redo: value))
            next.value = value
        }
        next.receipts[delivery.token.command.uuidString] = effects
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(next).write(to: stateURL, options: .atomic)
            state = next
            return outcome(effects)
        } catch { return .unresolved }
    }

    func outcome(for token: HistoryToken) async -> HistoryHostOutcome {
        guard let effects = state.receipts[token.command.uuidString] else { return .unresolved }
        return outcome(effects)
    }

    private func outcome(_ effects: [Effect]) -> HistoryHostOutcome {
        .accepted(effects.map { effect in
            HistoryEffect(memberID: effect.memberID, undo: recipe.payload(effect.undo),
                          redo: recipe.payload(effect.redo), resources: [recipe.resource])
        })
    }
}

extension HistoryOpeningCompatibilityTests {
    func testPreviewBaselineRecipeRetainsPairedHistoryStateCodecsAndResources() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #if SWIFT_PACKAGE
        let fixtures = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures")
        #else
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        #endif
        let recipeURL = fixtures.appendingPathComponent("preview-baseline.json")
        let recipe = try JSONDecoder().decode(PreviewBaselineRecipe.self, from: Data(contentsOf: recipeURL))
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(recipe.resourceFile),
                                        to: directory.appendingPathComponent(recipe.resourceFile))
        let host = try PreviewBaselineHost(recipe: recipe, directory: directory)
        let store = try await HistoryStore.open(at: directory.appendingPathComponent("History.sqlite"),
                                                workingIdentity: recipe.workingIdentity, mode: .create)
        let engine = try await store.openScope(recipe.scopeIdentity, mode: .create, host: host)
        try await populateBaseline(recipe, engine: engine, host: host)

        // Capture matching host state/resources while all history admission is fenced.
        let paired = directory.appendingPathComponent("paired")
        try FileManager.default.createDirectory(at: paired, withIntermediateDirectories: false)
        let copiedURL = paired.appendingPathComponent("History.sqlite")
        try await store.withCoordinatedCopy(to: copiedURL) { _ in
            for name in ["host-state.json", recipe.resourceFile] {
                try FileManager.default.copyItem(at: directory.appendingPathComponent(name),
                                                to: paired.appendingPathComponent(name))
            }
            try FileManager.default.copyItem(at: recipeURL, to: paired.appendingPathComponent("recipe.json"))
        }
        try await store.close()
        let before = try artifacts(at: copiedURL)
        let reader = try await HistoryStore.open(at: copiedURL, workingIdentity: recipe.workingIdentity,
                                                 mode: .existing, access: .readOnly)
        XCTAssertEqual(try reader.historyPage(scope: recipe.scopeIdentity, limit: 10).map(\.sequence),
                       recipe.expectedHistorySequences)
        XCTAssertEqual(try reader.requiredObjects(in: recipe.retentionStoreIdentity, limit: 10)
            .objects.map(\.reference),
                       [recipe.resource])
        try await reader.close()
        XCTAssertEqual(try artifacts(at: copiedURL), before)

        try await checkReopenedBaseline(recipe, directory: paired, storeURL: copiedURL)

        // Opt-in export retains the concrete matched pair for candidate sealing.
        if let output = ProcessInfo.processInfo.environment["UNDOKIT_BASELINE_OUTPUT"] {
            let destination = URL(fileURLWithPath: output, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                XCTFail("Baseline export destination must be absent")
                return
            }
            try FileManager.default.copyItem(at: paired, to: destination)
        }
    }
    private func checkReopenedBaseline(_ recipe: PreviewBaselineRecipe, directory paired: URL,
                                       storeURL copiedURL: URL) async throws {
        let reopenedHost = try PreviewBaselineHost(recipe: recipe, directory: paired)
        let reopened = try await HistoryStore.open(at: copiedURL,
            workingIdentity: recipe.workingIdentity, mode: .existing)
        let reopenedEngine = try await reopened.openScope(recipe.scopeIdentity, mode: .existing, host: reopenedHost)
        XCTAssertEqual(reopenedHost.value, recipe.expectedFinalHostValue)
        XCTAssertEqual(reopenedHost.receiptCount, 4)
        XCTAssertEqual(try reopenedEngine.historyPage(limit: 10).map { $0.kind.rawValue }, recipe.expectedHistoryKinds)
        XCTAssertEqual(try reopenedEngine.checkpoint(id: recipe.checkpointIdentity)?.state,
                       recipe.payload(recipe.expectedCheckpointValue))
        let entries = try reopenedEngine.historyPage(limit: 10)
        let plan = try reopenedEngine.beginRecoveryPlan(from: .checkpoint(recipe.checkpointIdentity),
            to: .group(entries[1].groupID), using: .acceptedEffects)
        let page = try reopenedEngine.recoveryPage(plan, limit: 10)
        XCTAssertEqual(page.steps.count, 1)
        let material = try reopenedEngine.recoveryMaterial(plan, groupID: entries[1].groupID, ordinal: 0)
        XCTAssertEqual(material.payload, recipe.payload(7))
        reopenedEngine.releaseRecoveryPlan(plan)
        try await reopened.close()
    }

    private func populateBaseline(_ recipe: PreviewBaselineRecipe, engine: HistoryEngine,
                                  host: PreviewBaselineHost) async throws {
        for (index, command) in recipe.commands.enumerated() {
            let members = zip(command.memberIDs, command.values).map { id, value in
                HistoryMember(id: id, payload: recipe.payload(value))
            }
            guard case .accepted = await engine.submit(HistoryCommand(id: command.id,
                fingerprint: Data("preview command \(index + 1)".utf8), members: members)) else {
                XCTFail("Baseline command failed")
                return
            }
            if index == 0 {
                _ = try engine.createCheckpoint(id: recipe.checkpointIdentity, name: "Eleven",
                    state: recipe.payload(host.value), resources: [recipe.resource])
            }
        }
        guard case .accepted = await engine.undo() else {
            XCTFail("Baseline Undo failed")
            return
        }
        XCTAssertEqual(host.value, recipe.expectedCheckpointValue)
        guard case .accepted = await engine.redo() else {
            XCTFail("Baseline Redo failed")
            return
        }
        XCTAssertEqual(host.value, recipe.expectedFinalHostValue)

    }

}
