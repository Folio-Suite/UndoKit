// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import Foundation
import Darwin

public struct ScaleBudgets: Codable, Sendable {
    public var seconds: Double
    public var residentBytes: UInt64
    public var ownedBytes: UInt64
    public var minimumFreeBytes: UInt64
    public var ordinaryHeartbeatSeconds: Double
    public static let mac = ScaleBudgets(seconds: 600, residentBytes: 2 * 1024 * 1024 * 1024,
        ownedBytes: 12 * 1024 * 1024 * 1024, minimumFreeBytes: 20 * 1024 * 1024 * 1024, ordinaryHeartbeatSeconds: 1)
    public static let device = ScaleBudgets(seconds: 900, residentBytes: 512 * 1024 * 1024,
        ownedBytes: 2 * 1024 * 1024 * 1024, minimumFreeBytes: 4 * 1024 * 1024 * 1024, ordinaryHeartbeatSeconds: 1)
    public init(seconds: Double, residentBytes: UInt64, ownedBytes: UInt64, minimumFreeBytes: UInt64,
                ordinaryHeartbeatSeconds: Double = 1) {
        self.seconds = seconds; self.residentBytes = residentBytes; self.ownedBytes = ownedBytes
        self.minimumFreeBytes = minimumFreeBytes; self.ordinaryHeartbeatSeconds = ordinaryHeartbeatSeconds
    }
}
func monotonic() -> Double { ProcessInfo.processInfo.systemUptime }
func residentBytes() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return UInt64(max(0, usage.ru_maxrss))
}
func footprint(_ directory: URL) -> UInt64 {
    guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return 0 }
    var bytes: UInt64 = 0
    var directoryInfo = stat()
    if lstat(directory.path, &directoryInfo) == 0 { bytes += UInt64(max(0, directoryInfo.st_blocks)) * 512 }
    for case let url as URL in files {
        var info = stat()
        if lstat(url.path, &info) == 0 { bytes += UInt64(max(0, info.st_blocks)) * 512 }
    }
    return bytes
}
func diskComponents(_ directory: URL) -> (history: UInt64, host: UInt64) {
    let total = footprint(directory)
    var history: UInt64 = 0
    for suffix in ["", "-wal", "-shm"] {
        var info = stat()
        if lstat(directory.appendingPathComponent("History.sqlite" + suffix).path, &info) == 0 {
            history += UInt64(max(0, info.st_blocks)) * 512
        }
    }
    return (history, total >= history ? total - history : 0)
}

@MainActor final class ScaleMonitor {
    let directory: URL
    let budgets: ScaleBudgets
    let started = monotonic()
    var peakResident: UInt64 = 0
    var peakOwned: UInt64 = 0
    var maximumOrdinaryGap = 0.0
    var ordinary = false
    var phase = "opening"
    var failure: Error?
    var task: Task<Void, Never>?
    init(directory: URL, budgets: ScaleBudgets) { self.directory = directory; self.budgets = budgets }
    func start() throws {
        try sample()
        task = Task { @MainActor [weak self] in
            var previous = monotonic()
            var sampled = previous
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self else { return }
                let now = monotonic()
                if self.ordinary { self.maximumOrdinaryGap = max(self.maximumOrdinaryGap, now - previous) }
                previous = now
                if now - sampled >= 0.5 {
                    do { try self.sample() } catch { self.failure = error }
                    sampled = now
                }
            }
        }
    }
    func check() throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        try require(monotonic() - started <= budgets.seconds, "Runtime budget exceeded in \(phase)")
    }
    func sample() throws {
        var owned = footprint(directory)
        #if os(iOS)
        // Count every repetition and installed app/runtime/resources, not only this fixture.
        owned = footprint(directory.deletingLastPathComponent()) + footprint(Bundle.main.bundleURL)
        #endif
        peakResident = max(peakResident, residentBytes()); peakOwned = max(peakOwned, owned)
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        let free = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        try require(peakResident <= budgets.residentBytes, "RSS budget exceeded in \(phase)")
        try require(peakOwned <= budgets.ownedBytes, "Owned disk budget exceeded in \(phase)")
        try require(free >= budgets.minimumFreeBytes, "Free disk budget exceeded in \(phase)")
        try check()
    }
    func stop() { task?.cancel() }
}
