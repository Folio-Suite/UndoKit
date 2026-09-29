// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import Foundation
import Testing
import PackageProbe

@MainActor struct PackageProbeTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory
        let root = temporary.appendingPathComponent("folio-package-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try body(root)
            if ProcessInfo.processInfo.environment["PACKAGE_PROBE_KEEP_FIXTURES"] != "1" {
                try FileManager.default.removeItem(at: root)
            }
        } catch {
            print("Failed package fixture retained at \(root.path)")
            throw error
        }
    }

    private func hostBytes(_ url: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        var bytes: [String: Data] = [:]
        for file in files where !file.hasDirectoryPath && !file.lastPathComponent.hasPrefix("History.sqlite") {
            bytes[file.lastPathComponent] = try Data(contentsOf: file)
        }
        let resources = url.appendingPathComponent("Resources")
        for file in try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) {
            bytes["Resources/" + file.lastPathComponent] = try Data(contentsOf: file)
        }
        return bytes
    }

    @Test func coherentCopyAndIndependentRegistration() throws {
      try fixture { root in
        let original = root.appendingPathComponent("original")
        let copy = root.appendingPathComponent("copy")
        let host = try PackageProbe.create(at: original)
        try host.save(scope: "document", text: "First", resource: "image-one")
        try host.save(scope: "document", text: "Second", resource: "image-two")
        let identity = host.identity
        #expect(FileManager.default.fileExists(atPath: original.appendingPathComponent("History.sqlite-wal").path))
        try host.capture(to: copy, independent: true)
        let reopened = try PackageProbe.open(at: copy)
        #expect(reopened.identity != identity)
        #expect(try reopened.snapshot(scope: "document") == ProbeSnapshot(text: "Second", resource: "image-two", history: ["First", "Second"], generation: 1, recording: true))
        let sourceState = try host.snapshot(scope: "document")
        let copyState = try reopened.snapshot(scope: "document")
        #expect(sourceState == copyState)
        #expect(try host.historicalResources(scope: "document", kind: .action) == ["image-one", "image-two"])
        #expect(try reopened.historicalResources(scope: "document", kind: .action) == ["image-one", "image-two"])
        #expect(throws: PackageFailure.identityMismatch) {
            try PackageProbe.open(at: copy, expectedIdentity: identity)
        }
        try reopened.save(scope: "document", text: "Copy edit", resource: "copy-resource")
        #expect(try host.snapshot(scope: "document").text == "Second")
        #expect(try host.historicalResources(scope: "document", kind: .action) == ["image-one", "image-two"])
        try host.close(); try reopened.close()
      }
    }

    @Test func moveSaveAsAndRestorationPreserveDisplacedState() throws {
      try fixture { root in
        let start = root.appendingPathComponent("start")
        let moved = root.appendingPathComponent("moved")
        let saveAs = root.appendingPathComponent("save-as")
        let host = try PackageProbe.create(at: start)
        try host.save(scope: "document", text: "A", resource: "asset-A")
        let identity = host.identity
        try host.move(to: moved)
        #expect(host.identity == identity)
        #expect(!FileManager.default.fileExists(atPath: start.path))
        try host.capture(to: saveAs, independent: true)
        let selected = try PackageProbe.open(at: saveAs)
        try host.save(scope: "document", text: "B", resource: "asset-B")
        try host.restore(from: selected, scope: "document")
        #expect(try host.snapshot(scope: "document").text == "A")
        #expect(try host.snapshot(scope: "document").resource == "asset-A")
        #expect(try host.displaced(scope: "document") == ["B"])
        #expect(try host.historicalResources(scope: "document", kind: .displaced) == ["asset-B"])
        #expect(try host.historicalResources(scope: "document", kind: .action) == ["asset-A", "asset-B", "asset-A"])
        #expect(try host.snapshot(scope: "document").history == ["A", "B", "A"])
        try host.close(); try selected.close()
      }
    }

    @Test func recordingGapCheckpointAndOmissionRetainCurrentResource() throws {
      try fixture { root in
        var host = try PackageProbe.create(at: root.appendingPathComponent("document"))
        try host.save(scope: "document", text: "Before", resource: "image-before")
        try host.setRecording(false)
        try host.save(scope: "document", text: "Gap", resource: "image-current")
        try host.checkpoint(scope: "document")
        #expect(try host.snapshot(scope: "document").history == ["Before"])
        #expect(try host.checkpoints(scope: "document") == ["Gap"])
        #expect(try host.historicalResources(scope: "document", kind: .checkpoint) == ["image-current"])
        try host.setRecording(true)
        #expect(try host.baseline(scope: "document") == ["Gap"])
        #expect(try host.historicalResources(scope: "document", kind: .baseline) == ["image-current"])
        try host.save(scope: "document", text: "After", resource: "image-after")
        let original = try hostBytes(root.appendingPathComponent("document"))
        #expect(throws: PackageFailure.injectedFailure) { try host.omitHistory(simulateFailure: true) }
        #expect(try hostBytes(root.appendingPathComponent("document")) == original)
        #expect(try host.snapshot(scope: "document").history == ["Before", "After"])
        #expect(try host.historicalResources(scope: "document", kind: .action) == ["image-before", "image-after"])
        #expect(try host.historicalResources(scope: "document", kind: .checkpoint) == ["image-current"])
        #expect(host.generation == 1)
        try host.close()
        host = try PackageProbe.open(at: root.appendingPathComponent("document"))
        #expect(try host.checkpoints(scope: "document") == ["Gap"])
        try host.omitHistory()
        #expect(try host.snapshot(scope: "document") == ProbeSnapshot(text: "After", resource: "image-after", history: [], generation: 2, recording: true))
        #expect(try host.historicalResources(scope: "document", kind: .action).isEmpty)
        #expect(try host.checkpoints(scope: "document").isEmpty)
        try host.close()
      }
    }

    @Test func migrationStagesAndPreservesOriginalOnInterruption() throws {
      try fixture { root in
        let path = root.appendingPathComponent("legacy")
        let host = try PackageProbe.create(at: path, legacy: true)
        try host.save(scope: "document", text: "Old", resource: "old-asset")
        let identity = host.identity
        let original = try hostBytes(path)
        #expect(throws: PackageFailure.injectedFailure) { try host.migrate(simulateInterruption: true) }
        #expect(try hostBytes(path) == original)
        #expect(try host.snapshot(scope: "document").history == ["Old"])
        #expect(try host.historicalResources(scope: "document", kind: .action) == ["old-asset"])
        try host.close()
        let old = try PackageProbe.open(at: path, expectedIdentity: identity)
        #expect(try old.snapshot(scope: "document").resource == "old-asset")
        try old.migrate()
        #expect(try old.snapshot(scope: "document") == ProbeSnapshot(text: "Old", resource: "old-asset", history: ["Old"], generation: 1, recording: true))
        try old.close()
        let upgraded = try PackageProbe.open(at: path, expectedIdentity: identity)
        try upgraded.save(scope: "document", text: "New", resource: "new-asset")
        #expect(try upgraded.snapshot(scope: "document").history == ["Old", "New"])
        #expect(try upgraded.historicalResources(scope: "document", kind: .action) == ["old-asset", "new-asset"])
        try upgraded.close()
      }
    }

    @Test func openingDistinguishesFailuresWithoutRewriting() throws {
      try fixture { root in
        let path = root.appendingPathComponent("document")
        let host = try PackageProbe.create(at: path)
        try host.save(scope: "document", text: "Protected", resource: "asset")
        try host.close()
        let manifest = path.appendingPathComponent("manifest.json")
        let database = path.appendingPathComponent("History.sqlite")
        let baselineManifest = try Data(contentsOf: manifest)
        let baselineDatabase = try Data(contentsOf: database)
        #expect(throws: PackageFailure.unavailableHistory) { try PackageProbe.open(at: path, simulateUnavailable: true) }
        #expect(try Data(contentsOf: database) == baselineDatabase)

        let fixture = try PackageProbe.open(at: path)
        try fixture.fixtureManifest(codec: "future-codec")
        try fixture.close()
        let unknownCodec = try Data(contentsOf: manifest)
        let codecDatabase = try Data(contentsOf: database)
        #expect(throws: PackageFailure.unknownCodec) { try PackageProbe.open(at: path) }
        #expect(try Data(contentsOf: manifest) == unknownCodec)
        #expect(try Data(contentsOf: database) == codecDatabase)

        // Restore only the fixture control bytes before testing a newer structural version.
        try baselineManifest.write(to: manifest, options: .atomic)
        let newer = try PackageProbe.open(at: path)
        try newer.fixtureManifest(schema: 99)
        try newer.close()
        let unknownSchema = try Data(contentsOf: manifest)
        let schemaDatabase = try Data(contentsOf: database)
        #expect(throws: PackageFailure.newerSchema) { try PackageProbe.open(at: path) }
        #expect(try Data(contentsOf: manifest) == unknownSchema)
        #expect(try Data(contentsOf: database) == schemaDatabase)

        try baselineManifest.write(to: manifest, options: .atomic)
        try FileManager.default.removeItem(at: database)
        #expect(throws: PackageFailure.missingHistory) { try PackageProbe.open(at: path) }
        #expect(!FileManager.default.fileExists(atPath: database.path))

        try Data("not sqlite".utf8).write(to: database)
        let corruptBytes = try Data(contentsOf: database)
        #expect(throws: PackageFailure.corruptHistory) { try PackageProbe.open(at: path) }
        #expect(try Data(contentsOf: database) == corruptBytes)
        #expect(baselineDatabase != corruptBytes)

        let empty = try PackageProbe.create(at: root.appendingPathComponent("deliberately-empty"), historyFree: true)
        try empty.close()
        let reopenedEmpty = try PackageProbe.open(at: root.appendingPathComponent("deliberately-empty"))
        #expect(try reopenedEmpty.snapshot(scope: "document").history.isEmpty)
        try reopenedEmpty.close()
      }
    }

    @Test func appLocalMultiScopeAndUnresolvedCapture() throws {
      try fixture { root in
        let path = root.appendingPathComponent("Application Support").appendingPathComponent("History")
        let host = try PackageProbe.create(at: path)
        try host.save(scope: "kitchen-one", text: "Soup", resource: "photo-one")
        try host.save(scope: "kitchen-two", text: "Bread", resource: "photo-two")
        try host.capture(to: root.appendingPathComponent("backup"), independent: false)
        #expect(try host.snapshot(scope: "kitchen-one").history == ["Soup"])
        #expect(try host.snapshot(scope: "kitchen-two").history == ["Bread"])
        let backup = try PackageProbe.open(at: root.appendingPathComponent("backup"))
        #expect(try backup.historicalResources(scope: "kitchen-one", kind: .action) == ["photo-one"])
        #expect(try backup.historicalResources(scope: "kitchen-two", kind: .action) == ["photo-two"])
        try backup.close()
        try host.save(scope: "kitchen-one", text: "Soup again", resource: "photo-one-new")
        try host.omitHistory()
        #expect(try host.snapshot(scope: "kitchen-one").resource == "photo-one-new")
        #expect(try host.snapshot(scope: "kitchen-two").resource == "photo-two")
        #expect(try host.snapshot(scope: "kitchen-two").history.isEmpty)
        try host.fixtureManifest(unresolved: true)
        #expect(throws: PackageFailure.unresolved) {
            try host.capture(to: root.appendingPathComponent("unsafe-copy"), independent: true)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unsafe-copy").path))
        try host.close()
      }
    }

    @Test func promotionFaultsRestoreOriginalAndAllowLaterEdits() throws {
      try fixture { root in
        for fault in [PromotionFault.afterOriginalMoved, .afterNewAttached] {
            let path = root.appendingPathComponent("legacy-\(fault.rawValue)")
            var host = try PackageProbe.create(at: path, legacy: true)
            try host.save(scope: "document", text: "Old", resource: "asset-old")
            let expected = try hostBytes(path)
            #expect(throws: PackageFailure.injectedFailure) {
                try host.migrate(promotionFault: fault)
            }
            #expect(try hostBytes(path) == expected)
            try host.close()
            host = try PackageProbe.open(at: path)
            #expect(try host.historicalResources(scope: "document", kind: .action) == ["asset-old"])
            try host.save(scope: "document", text: "Still editable", resource: "asset-next")
            #expect(try host.snapshot(scope: "document").history == ["Old", "Still editable"])
            try host.close()
        }
        let path = root.appendingPathComponent("omit")
        var host = try PackageProbe.create(at: path)
        try host.save(scope: "document", text: "Keep", resource: "keep-asset")
        #expect(throws: PackageFailure.injectedFailure) {
            try host.omitHistory(promotionFault: .afterNewAttached)
        }
        try host.close()
        host = try PackageProbe.open(at: path)
        #expect(host.generation == 1)
        #expect(try host.historicalResources(scope: "document", kind: .action) == ["keep-asset"])
        try host.save(scope: "document", text: "Later", resource: "later-asset")
        #expect(try host.snapshot(scope: "document").history == ["Keep", "Later"])
        try host.close()
      }
    }

    @Test func failedMoveReopensOriginalBeforeLaterSave() throws {
      try fixture { root in
        let path = root.appendingPathComponent("original")
        let host = try PackageProbe.create(at: path)
        try host.save(scope: "document", text: "Before", resource: "first")
        #expect(throws: PackageFailure.injectedFailure) {
            try host.move(to: root.appendingPathComponent("new-place"), simulateFailure: true)
        }
        do {
            try host.move(to: root.appendingPathComponent("missing-parent").appendingPathComponent("new-place"))
            Issue.record("Move unexpectedly succeeded without a destination parent")
        } catch {
            #expect(FileManager.default.fileExists(atPath: path.path))
        }
        try host.save(scope: "document", text: "After", resource: "second")
        #expect(try host.historicalResources(scope: "document", kind: .action) == ["first", "second"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("new-place").path))
        try host.close()
        let reopened = try PackageProbe.open(at: path)
        #expect(try reopened.snapshot(scope: "document").history == ["Before", "After"])
        try reopened.close()
      }
    }
}
