// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import SwiftUI
import Foundation
import UndoKit

@main struct ScaleDeviceApp: App {
    var body: some Scene { WindowGroup { ScaleDeviceView() } }
}

struct ScaleDeviceView: View {
    @State private var seed = 11
    @State private var status = "Ready. Physical acceptance requires 3 fixtures and 10 fresh launches per fixture."
    @State private var active: Task<Void, Never>?
    @State private var started = false
    @State private var count = 10_000
    private var fullProfile: Bool {
        #if targetEnvironment(simulator)
        guard argument("--scale-profile") == "simulator-full",
              let manifestURL = Bundle.main.url(forResource: "BuildManifest", withExtension: "json"),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["sdk"] as? String == "iphonesimulator",
              manifest["profile"] as? String == "simulator-full",
              let budgets = manifest["budgets"] as? [String: Any],
              (budgets["seconds"] as? NSNumber)?.doubleValue == 900,
              (budgets["residentBytes"] as? NSNumber)?.uint64Value == 2 * 1024 * 1024 * 1024,
              (budgets["evidenceAllocatedBytes"] as? NSNumber)?.uint64Value == 2 * 1024 * 1024 * 1024,
              (budgets["minimumFreeBytes"] as? NSNumber)?.uint64Value == 4 * 1024 * 1024 * 1024,
              (budgets["ordinaryHeartbeatSeconds"] as? NSNumber)?.doubleValue == 1 else { return false }
        return true
        #else
        return false
        #endif
    }
    private var budgets: ScaleBudgets { fullProfile ? ScaleBudgets(seconds: 900, residentBytes: 2 * 1024 * 1024 * 1024, ownedBytes: 2 * 1024 * 1024 * 1024, minimumFreeBytes: 4 * 1024 * 1024 * 1024, ordinaryHeartbeatSeconds: 1) : .device }
    private var arguments: [String] { CommandLine.arguments }
    private func argument(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Production scale fixture") {
                    Picker("Deterministic seed", selection: $seed) {
                        ForEach(11...13, id: \.self) { Text("\($0)").tag($0) }
                    }.disabled(active != nil)
                    Text("\(count) groups; 1% trunk, two distant continuations; multi-Action groups and shared resource.")
                    Text(fullProfile ? "Full simulator profile: 15 minutes, 2 GiB app RSS, 2 GiB fixture and installed app, 4 GiB remaining free space. Ordinary heartbeat: 1 second." : "Smoke profile: 15 minutes, 512 MiB process RSS, 2 GiB evidence, 4 GiB remaining free space.")
                    Button("Create fixture") { run(operation: "create", sample: 0) }.disabled(active != nil)
                    Button("Read back in this process") { run(operation: "reopen", sample: 0) }.disabled(active != nil)
                    if active != nil { Button("Cancel preparation", role: .cancel) { active?.cancel() } }
                }
                Section("Observed phase / result") { Text(status).textSelection(.enabled) }
                Section("Fresh-process evidence") {
                    Text("Launch arguments: --scale-operation reopen --scale-seed 11 --scale-sample 1. Stop the completed process and repeat with samples 1–10 for each seed. A current-process readback is labelled sample 0 and is excluded from fresh-process acceptance.")
                    Text("Export Application Support/UndoKitScaleEvidence using Xcode's container download. This app records runtime, hardware, budgets, process IDs, phase, full allocated footprint and reports. Toolchain/source/artifact identity is in the build manifest embedded with the app.")
                }
            }.navigationTitle("UndoKit Scale")
        }.task {
            guard !started else { return }; started = true
            if let parsed = argument("--scale-seed").flatMap(Int.init) { seed = parsed }
            if let parsed = argument("--scale-groups").flatMap(Int.init) { count = parsed }
            if let operation = argument("--scale-operation") {
                run(operation: operation, sample: argument("--scale-sample").flatMap(Int.init) ?? 0)
            }
        }
    }
    @MainActor private func run(operation: String, sample: Int) {
        active = Task { @MainActor in
            var directory: URL?
            do {
                let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("UndoKitScaleEvidence")
                let fixture = root.appendingPathComponent("seed-\(seed)"); directory = fixture
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let inventoryStart = ProcessInfo.processInfo.systemUptime
                let installedArtifact = try ScaleArtifact.inventory(directory: Bundle.main.bundleURL)
                let inventorySeconds = ProcessInfo.processInfo.systemUptime - inventoryStart
                if operation == "create" {
                    guard !FileManager.default.fileExists(atPath: fixture.appendingPathComponent("History.sqlite").path) else {
                        throw ScaleFailure.assertion("Fixture exists. Export its evidence, then delete app data before recreating this seed.")
                    }
                    var report = try await ScaleWorkload.create(directory: fixture, groups: count, seed: seed, budgets: budgets) { phase in
                        status = phase
                        try? Data(phase.utf8).write(to: fixture.appendingPathComponent("Phase.txt"), options: .atomic)
                    }
                    report.installedArtifactSHA256 = installedArtifact
                    if fullProfile { report.platform = "iOS Simulator" }
                    report.artifactInventorySeconds = inventorySeconds
                    if let manifest = Bundle.main.url(forResource: "BuildManifest", withExtension: "json") {
                        try Data(contentsOf: manifest).write(to: fixture.appendingPathComponent("BuildManifest.json"), options: .atomic)
                    }
                    try encoder.encode(report).write(to: fixture.appendingPathComponent("WorkloadReport.json"), options: .atomic)
                    status = "Fixture completed; fresh-process samples and physical responsiveness review remain."
                } else if operation == "reopen" {
                    guard (0...10).contains(sample) else { throw ScaleFailure.assertion("Reopen sample must be 1–10 (0 = in-process diagnostic)") }
                    let path = fixture.appendingPathComponent("Reopen-\(sample).json")
                    guard !FileManager.default.fileExists(atPath: path.path) else { throw ScaleFailure.assertion("Sample already exists; evidence cannot be overwritten") }
                    let creation = try JSONDecoder().decode(ScaleWorkloadReport.self,
                        from: Data(contentsOf: fixture.appendingPathComponent("WorkloadReport.json")))
                    guard creation.installedArtifactSHA256 == installedArtifact else {
                        throw ScaleFailure.assertion("Installed artifact differs from the fixture's creation process")
                    }
                    var report = try await ScaleWorkload.reopen(directory: fixture, budgets: budgets)
                    report.installedArtifactSHA256 = installedArtifact
                    report.artifactInventorySeconds = inventorySeconds
                    try encoder.encode(report).write(to: path, options: .atomic)
                    status = "Readback \(sample) completed; process \(report.processID), value \(report.hostValue)."
                } else { throw ScaleFailure.assertion("Unknown operation") }
            } catch {
                status = "FAILED: \(error)"
                if let directory {
                    let failure: [String: String] = ["result": "failed", "error": String(describing: error),
                        "processID": String(ProcessInfo.processInfo.processIdentifier),
                        "os": ProcessInfo.processInfo.operatingSystemVersionString,
                        "peakResidentBytes": String(residentBytes()), "fullEvidenceAllocatedBytes": String(footprint(directory))]
                    try? JSONEncoder().encode(failure).write(to: directory.appendingPathComponent("Failure-\(UUID()).json"), options: .atomic)
                }
            }
            active = nil
        }
    }
}
