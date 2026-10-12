// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import Foundation
import UndoKit

public enum ScaleFailure: Error, CustomStringConvertible {
    case assertion(String)
    public var description: String { if case .assertion(let message) = self { return message }; return "scale failure" }
}
func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ScaleFailure.assertion(message) }
}
func identifier(_ seed: Int, _ kind: Int, _ index: Int) -> UUID {
    UUID(uuidString: String(format: "%08x-%04x-4000-8000-%012x", seed, kind, index))!
}
func scalePayload(_ value: Int, bytes: Int = 336) -> HistoryPayload {
    var data = Data("\(value)|".utf8)
    data.append(Data(repeating: 120, count: max(0, bytes - data.count)))
    return HistoryPayload(family: "scale-counter-v1", data: data)
}
func decodeState(_ data: Data) throws -> Int {
    guard let delimiter = data.firstIndex(of: 124),
          let text = String(data: data[..<delimiter], encoding: .utf8), let value = Int(text) else {
        throw ScaleFailure.assertion("Invalid scale host state encoding")
    }
    return value
}
func scaleCommand(seed: Int, index: Int) -> HistoryCommand {
    let count = index.isMultiple(of: 10) ? 2 : 1
    let bytes = index.isMultiple(of: 997) ? 349_520 / count : 336 / count
    let members = (0..<count).map { ordinal in
        HistoryMember(id: identifier(seed, 3 + ordinal, index),
            payload: scalePayload(seed * 100_000 + index * 2 - (count - ordinal - 1), bytes: bytes))
    }
    return HistoryCommand(id: identifier(seed, 2, index), fingerprint: Data("set:\(seed):\(index)".utf8), members: members)
}
struct StoredMember: Codable { var id: UUID; var before: Int; var after: Int; var bytes: Int }
struct StoredReceipt: Codable { var key: String; var members: [StoredMember]; var state: HostSnapshot }
struct HostSnapshot: Codable { var value = 0; var deliveries = 0; var members = 0; var encodedPayloadBytes = 0 }

/// Compact authoritative receipts and durable host state. Measures graceful reopening,
/// not atomic host crash recovery or a production host database's throughput.
actor ScaleHost: HistoryHost {
    let directory: URL
    let resource: HistoryObjectReference
    var state: HostSnapshot
    var outcomes: [String: StoredReceipt] = [:]
    var deliveryLatencies: [Double] = []
    let journal: FileHandle
    init(directory: URL, seed: Int) throws {
        self.directory = directory
        resource = HistoryObjectReference(storeID: identifier(seed, 9, 0), objectKey: "shared", versionKey: "v1")
        state = HostSnapshot()
        let receiptURL = directory.appendingPathComponent("Receipts.jsonl")
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            for line in try Data(contentsOf: receiptURL).split(separator: 10) {
                let receipt = try JSONDecoder().decode(StoredReceipt.self, from: Data(line))
                outcomes[receipt.key] = receipt
                state = receipt.state
            }
        } else { FileManager.default.createFile(atPath: receiptURL.path, contents: nil) }
        journal = try FileHandle(forWritingTo: receiptURL)
        try journal.seekToEnd()
    }
    func deliver(_ delivery: HistoryDelivery) async -> HistoryHostOutcome {
        let started = monotonic()
        let key = Self.key(delivery.token)
        if let prior = outcomes[key] { return outcome(prior) }
        do {
            var next = state
            var members: [StoredMember] = []
            for member in delivery.members {
                let value = try decodeState(member.payload.data)
                members.append(StoredMember(id: member.id, before: next.value, after: value, bytes: member.payload.data.count))
                next.value = value
            }
            next.deliveries += 1; next.members += members.count
            next.encodedPayloadBytes += members.reduce(0) { $0 + $1.bytes * 3 }
            let receipt = StoredReceipt(key: key, members: members, state: next)
            var bytes = try JSONEncoder().encode(receipt); bytes.append(10)
            try journal.write(contentsOf: bytes)
            try journal.synchronize()
            state = next; outcomes[key] = receipt
            deliveryLatencies.append(monotonic() - started)
            return outcome(receipt)
        } catch { return .unresolved }
    }
    func outcome(for token: HistoryToken) async -> HistoryHostOutcome { outcomes[Self.key(token)].map(outcome) ?? .rejected }
    func snapshot() -> HostSnapshot { state }
    func timings() -> [Double] { deliveryLatencies }
    func close() throws {
        try journal.synchronize()
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("Host.json"), options: .atomic)
        try journal.close()
    }
    private static func key(_ token: HistoryToken) -> String {
        "\(token.scope):\(token.generation):\(token.sequence):\(token.command)"
    }
    private func outcome(_ receipt: StoredReceipt) -> HistoryHostOutcome {
        .accepted(receipt.members.map {
            HistoryEffect(memberID: $0.id, undo: scalePayload($0.before, bytes: $0.bytes),
                redo: scalePayload($0.after, bytes: $0.bytes), resources: [resource])
        })
    }
}
public struct ScaleManifest: Codable, Sendable {
    var seed: Int; var groups: Int; var firstGroup: UUID; var branchAGroup: UUID; var branchBGroup: UUID
    var firstReceiptSequence: Int64; var firstReceiptGeneration: UUID
    var ancestorCheckpoint: UUID; var currentCheckpoint: UUID; var holdIDs: [UUID]
    var expectedValue: Int; var expectedDeliveries: Int; var expectedMembers: Int; var expectedRetainedIDs: [UUID]
}
public struct ScaleReconstruction: Codable, Sendable {
    public var value: Int; public var recordsVisited: Int; public var bytesRead: Int
    public var firstResponseSeconds: Double; public var seconds: Double
}
public struct ScaleOutlier: Codable, Sendable { public var operation: Int; public var seconds: Double }
public struct ScaleDistribution: Codable, Sendable {
    public var count: Int; public var p50: Double; public var p95: Double; public var p99: Double
    public var maximum: Double; public var outliers: [ScaleOutlier]
    init(_ values: [Double]) {
        let sorted = values.sorted(); count = sorted.count
        func percentile(_ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        p50 = percentile(0.5); p95 = percentile(0.95); p99 = percentile(0.99); maximum = sorted.last ?? 0
        outliers = values.enumerated().sorted { $0.element > $1.element }.prefix(10).map {
            ScaleOutlier(operation: $0.offset + 1, seconds: $0.element)
        }
    }
}
public struct ScaleWorkloadReport: Codable, Sendable {
    public var seed: Int; public var groups: Int; public var trunkGroups: Int; public var branchAGroups: Int; public var branchBGroups: Int
    public var actionsPerGroup: [Int: Int]; public var encodedBytes: Int; public var groupEncodedByteSizes: [Int]
    public var allAcceptedEncodedPayloadBytes: Int
    public var controlledLimitRefusalVerified: Bool
    public var phases: [String: Double]; public var ordinarySubmission: ScaleDistribution; public var largeSubmission: ScaleDistribution
    public var inverse: ScaleDistribution; public var historyPages: ScaleDistribution
    public var hostDelivery: ScaleDistribution
    public var farBack: ScaleReconstruction; public var divergent: ScaleReconstruction
    public var returnToDisplaced: ScaleReconstruction; public var checkpointBaseline: ScaleReconstruction
    public var removedGroups: Int; public var consolidationPasses: Int; public var hostValue: Int
    public var peakResidentBytes: UInt64; public var peakOwnedAllocatedBytes: UInt64
    public var historyAllocatedBytes: UInt64; public var hostAllocatedBytes: UInt64
    public var maximumOrdinaryHeartbeatGapSeconds: Double; public var processID: Int32; public var hardware: String; public var os: String
    public var platform: String
    public var physicalMemoryBytes: UInt64
}
public struct ScaleReopenReport: Codable, Sendable {
    public var hostValue: Int; public var deliveries: Int; public var members: Int
    public var availabilitySeconds: Double; public var totalSeconds: Double; public var processID: Int32
    public var canUndo: Bool; public var canRedo: Bool; public var peakResidentBytes: UInt64
    public var peakOwnedAllocatedBytes: UInt64; public var historyAllocatedBytes: UInt64; public var hostAllocatedBytes: UInt64
}
