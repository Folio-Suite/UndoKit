// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import Foundation
import Testing
import RecoveryProbe

private func cleanup(_ directory: URL) {
    guard ProcessInfo.processInfo.environment["RECOVERY_PROBE_KEEP_FIXTURES"] != "1" else { return }
    try? FileManager.default.removeItem(at: directory)
}

@MainActor @Test func acceptedCommandSurvivesReopenWithoutDuplicateDelivery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let command = Command(scope: "work-a", id: "one", fingerprint: "add-one", kind: .ordinary, delta: 1)
    #expect(try probe.submit(command, host: host) == .accepted)
    #expect(try host.value(scope: "work-a") == 1)
    try probe.close()
    let reopened = try RecoveryProbe.open(directory: directory)
    #expect(try reopened.submit(command, host: host) == .accepted)
    #expect(try host.value(scope: "work-a") == 1)
    #expect(try reopened.snapshot(scope: "work-a").actions.count == 1)
}

@MainActor @Test func preparationAndCancellationNeverChangeHost() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let command = Command(scope: "a", id: "cancelled", fingerprint: "first", kind: .ordinary, delta: 4)
    probe.fault = .prepare
    #expect(throws: ProbeError.injectedFailure) { try probe.prepare(command) }
    #expect(try probe.snapshot(scope: "a").phase == nil)
    let token = try probe.prepare(command)
    #expect(try probe.snapshot(scope: "a").phase == .prepared)
    try probe.cancelBeforeDelivery(token)
    #expect(try host.value(scope: "a") == 0)
    #expect(try probe.snapshot(scope: "a").actions.isEmpty)
    try probe.close()
    let reopened = try RecoveryProbe.open(directory: directory)
    #expect(try reopened.snapshot(scope: "a").phase == nil)
}

@MainActor @Test func unknownOutcomeSuspendsOnlyItsScopeAndLaterReceiptRecovers() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let command = Command(scope: "a", id: "uncertain", fingerprint: "add-five", kind: .ordinary, delta: 5)
    let token = try probe.prepare(command)
    try probe.markDeliveryStarted(token)
    #expect(throws: ProbeError.unresolved) { try probe.reconcile(token, host: host) }
    #expect(try probe.snapshot(scope: "a").phase == .unresolved)
    #expect(try probe.snapshot(scope: "a").undoAvailable == false)
    #expect(try probe.submit(Command(scope: "b", id: "other", fingerprint: "add-two", kind: .ordinary, delta: 2), host: host) == .accepted)
    #expect(try host.value(scope: "b") == 2)
    try probe.close()
    let reopened = try RecoveryProbe.open(directory: directory)
    #expect(try reopened.snapshot(scope: "a").phase == .unresolved)
    _ = try host.apply(command)
    try reopened.recover(host: host)
    #expect(try reopened.snapshot(scope: "a").actions.count == 1)
    #expect(try host.value(scope: "a") == 5)
}

@MainActor @Test func hostAcceptedBeforeHistorySaveIsNeverAppliedTwice() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let command = Command(scope: "a", id: "one", fingerprint: "add-nine", kind: .ordinary, delta: 9)
    host.fault = .afterSave
    #expect(throws: ProbeError.injectedFailure) { try probe.submit(command, host: host) }
    #expect(try host.value(scope: "a") == 9)
    try probe.close()
    let reopened = try RecoveryProbe.open(directory: directory)
    try reopened.recover(host: host)
    #expect(try reopened.submit(command, host: host) == .accepted)
    #expect(try host.value(scope: "a") == 9)
    #expect(try reopened.snapshot(scope: "a").actions.count == 1)
    #expect(throws: ProbeError.conflict) {
        try reopened.submit(Command(scope: "a", id: "one", fingerprint: "different", kind: .ordinary, delta: 100), host: host)
    }
}

@MainActor @Test func acceptedInverseAndRejectedInverseKeepEligibilityHonest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let original = Command(scope: "a", id: "original", fingerprint: "plus-three", kind: .ordinary, delta: 3, groupID: "group")
    #expect(try probe.submit(original, host: host) == .accepted)
    let inverse = Command(scope: "a", id: "undo", fingerprint: "minus-three", kind: .undo, delta: -3,
                          groupID: "group", targetMemberID: "original")
    #expect(try probe.submit(inverse, host: host) == .accepted)
    #expect(try host.value(scope: "a") == 0)
    #expect(try probe.snapshot(scope: "a").undoAvailable == false)
    #expect(try probe.snapshot(scope: "a").redoAvailable == true)
    let compensationID = try #require(probe.snapshot(scope: "a").actions.first { $0.kind == .undo }?.id)
    let redo = Command(scope: "a", id: "redo", fingerprint: "plus-again", kind: .redo, delta: 3,
                       groupID: "group", targetMemberID: "original", compensationActionID: compensationID)
    host.nextOutcome = .rejected
    let token = try probe.prepare(redo)
    try probe.markDeliveryStarted(token)
    try probe.deliver(token, host: host)
    probe.fault = .invalidation
    #expect(throws: ProbeError.injectedFailure) { try probe.finalize(token) }
    #expect(try probe.snapshot(scope: "a").redoAvailable == false)
    try probe.close()
    let reopened = try RecoveryProbe.open(directory: directory)
    #expect(try reopened.snapshot(scope: "a").redoAvailable == false)
    try reopened.recover(host: host)
    #expect(try reopened.snapshot(scope: "a").redoAvailable == false)
    #expect(try reopened.snapshot(scope: "a").undoAvailable == false)
    #expect(try host.value(scope: "a") == 0)
}

@MainActor @Test func groupMustHaveWholeAuthoritativeMemberEvidence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let group = Command(scope: "a", id: "group-command", fingerprint: "two-members", kind: .ordinary,
                        groupID: "group", members: [Member(id: "first", delta: 2), Member(id: "second", delta: 3)])
    #expect(try probe.submit(group, host: host) == .accepted)
    #expect(try host.value(scope: "a") == 5)
    #expect(try probe.snapshot(scope: "a").actions.map(\.memberID) == ["first", "second"])
    #expect(Set(try probe.snapshot(scope: "a").actions.map(\.id)).count == 2)
    let another = Command(scope: "b", id: "malformed", fingerprint: "two-members", kind: .ordinary,
                          groupID: "group", members: [Member(id: "x", delta: 7), Member(id: "y", delta: 11)])
    host.malformedMemberEvidence = true
    #expect(throws: ProbeError.unresolved) { try probe.submit(another, host: host) }
    #expect(try host.value(scope: "b") == 18)
    #expect(try probe.snapshot(scope: "b").actions.isEmpty)
    #expect(try probe.snapshot(scope: "b").undoAvailable == false)
    #expect(try probe.snapshot(scope: "a").undoAvailable == true)
}

@MainActor @Test func rejectedOrdinaryCommandHasNoActionAndNoEffect() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let command = Command(scope: "a", id: "no-op", fingerprint: "no-op", kind: .ordinary, delta: 5)
    host.nextOutcome = .rejected
    #expect(try probe.submit(command, host: host) == .rejected)
    #expect(try host.value(scope: "a") == 0)
    #expect(try probe.snapshot(scope: "a").actions.isEmpty)
    #expect(try probe.submit(command, host: host) == .rejected)
    #expect(try host.value(scope: "a") == 0)
}

@MainActor @Test func failedHistoryFinalizationPreservesAcceptedEffectAcrossRepeatedReopens() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let command = Command(scope: "a", id: "accepted", fingerprint: "four", kind: .ordinary, delta: 4)
    let first = try RecoveryProbe.open(directory: directory)
    let token = try first.prepare(command)
    try first.markDeliveryStarted(token)
    try first.deliver(token, host: host)
    first.fault = .finalization
    #expect(throws: ProbeError.injectedFailure) { try first.finalize(token) }
    #expect(try first.snapshot(scope: "a").undoAvailable == false)
    try first.close()
    let second = try RecoveryProbe.open(directory: directory)
    #expect(try second.snapshot(scope: "a").phase == .acceptancePending)
    #expect(try second.snapshot(scope: "a").actions.isEmpty)
    try second.close()
    let third = try RecoveryProbe.open(directory: directory)
    try third.recover(host: host)
    #expect(try third.snapshot(scope: "a").actions.count == 1)
    #expect(try host.value(scope: "a") == 4)
}

@MainActor @Test func actualSIGKILLRecoveryAtTransactionBoundaries() throws {
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/RecoveryChild")
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    for mode in ["afterPrepare", "afterDelivery", "afterHostAcceptance", "afterAcceptanceRecord", "afterFinalization"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { cleanup(directory) }
        let process = Process()
        process.executableURL = executable
        process.arguments = [directory.path, mode]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal, "\(mode) must terminate by signal")
        #expect(process.terminationStatus == 9, "\(mode) must receive SIGKILL")
        let host = try HostStore.open(directory: directory)
        let first = try RecoveryProbe.open(directory: directory)
        if mode == "afterPrepare" {
            #expect(try first.snapshot(scope: "killed").phase == .prepared)
            try first.close()
            let second = try RecoveryProbe.open(directory: directory)
            #expect(try second.snapshot(scope: "killed").phase == .prepared)
            let token = try second.prepare(Command(scope: "killed", id: "child-one", fingerprint: "child-add-seven", kind: .ordinary, delta: 7))
            #expect(try second.resumePrepared(token, host: host) == .accepted)
            try second.close()
        } else if mode == "afterDelivery" {
            #expect(throws: ProbeError.unresolved) { try first.recover(host: host) }
            #expect(try first.snapshot(scope: "killed").undoAvailable == false)
            try first.close()
            let second = try RecoveryProbe.open(directory: directory)
            #expect(try second.snapshot(scope: "killed").phase == .unresolved)
            _ = try host.apply(Command(scope: "killed", id: "child-one", fingerprint: "child-add-seven", kind: .ordinary, delta: 7))
            try second.recover(host: host)
            try second.close()
        } else {
            try first.recover(host: host)
            try first.close()
        }
        let final = try RecoveryProbe.open(directory: directory)
        #expect(try final.snapshot(scope: "killed").actions.count == 1, "\(mode)")
        #expect(try host.value(scope: "killed") == 7, "\(mode)")
        print("SIGKILL \(mode): signal=\(process.terminationStatus), hostValue=7, actions=1")
        try final.close()
    }
}

@MainActor @Test func undoCannotSkipNewerAcceptedGroup() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    #expect(try probe.submit(Command(scope: "a", id: "first", fingerprint: "one", kind: .ordinary, delta: 1), host: host) == .accepted)
    #expect(try probe.submit(Command(scope: "a", id: "second", fingerprint: "two", kind: .ordinary, delta: 2), host: host) == .accepted)
    #expect(throws: ProbeError.invalidTransition) {
        try probe.submit(Command(scope: "a", id: "wrong-undo", fingerprint: "minus-one", kind: .undo, delta: -1,
                                 groupID: "first", targetMemberID: "first"), host: host)
    }
    #expect(try host.value(scope: "a") == 3)
}

@MainActor @Test func wholeGroupInverseAndRejectionAreAtomicToCaller() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let original = Command(scope: "a", id: "group", fingerprint: "two-adds", kind: .ordinary,
                           groupID: "g", members: [Member(id: "one", delta: 2), Member(id: "two", delta: 3)])
    #expect(try probe.submit(original, host: host) == .accepted)
    let inverse = Command(scope: "a", id: "inverse", fingerprint: "two-compensations", kind: .undo,
                          groupID: "g", members: [Member(id: "undo-two", delta: -3, targetMemberID: "two"),
                                                   Member(id: "undo-one", delta: -2, targetMemberID: "one")])
    host.nextOutcome = .rejected
    #expect(try probe.submit(inverse, host: host) == .rejected)
    #expect(try host.value(scope: "a") == 5)
    #expect(try probe.snapshot(scope: "a").actions.count == 2)
    #expect(try probe.snapshot(scope: "a").undoAvailable == false)
    #expect(try probe.snapshot(scope: "a").redoAvailable == false)
    let second = Command(scope: "b", id: "group", fingerprint: "two-adds", kind: .ordinary,
                         groupID: "g", members: [Member(id: "one", delta: 2), Member(id: "two", delta: 3)])
    #expect(try probe.submit(second, host: host) == .accepted)
    let acceptedInverse = Command(scope: "b", id: "inverse", fingerprint: "two-compensations", kind: .undo,
                                  groupID: "g", members: [Member(id: "undo-two", delta: -3, targetMemberID: "two"),
                                                           Member(id: "undo-one", delta: -2, targetMemberID: "one")])
    #expect(try probe.submit(acceptedInverse, host: host) == .accepted)
    #expect(try host.value(scope: "b") == 0)
    #expect(try probe.snapshot(scope: "b").actions.count == 4)
    #expect(try probe.snapshot(scope: "b").actions.filter { $0.kind == .undo }.map(\.targetMemberID) == ["two", "one"])
    #expect(try host.lookup(scope: "b", id: "inverse")?.targetMemberIDs == ["two", "one"])
    #expect(try probe.snapshot(scope: "b").redoAvailable == true)
    let compensation = try probe.snapshot(scope: "b").actions.filter { $0.kind == .undo }
    let compensationByTarget = Dictionary(uniqueKeysWithValues: compensation.map { ($0.targetMemberID!, $0.id) })
    let redo = Command(scope: "b", id: "redo", fingerprint: "ordered-reapplication", kind: .redo,
                       groupID: "g", members: [Member(id: "redo-one", delta: 2, targetMemberID: "one",
                                                      compensationActionID: compensationByTarget["one"]),
                                              Member(id: "redo-two", delta: 3, targetMemberID: "two",
                                                     compensationActionID: compensationByTarget["two"])])
    #expect(try probe.submit(redo, host: host) == .accepted)
    #expect(try probe.snapshot(scope: "b").actions.filter { $0.kind == .redo }.map(\.targetMemberID) == ["one", "two"])
    #expect(try probe.snapshot(scope: "b").actions.filter { $0.kind == .redo }.map(\.compensationActionID) ==
            [compensationByTarget["one"], compensationByTarget["two"]])
    #expect(try host.value(scope: "b") == 5)
}

@MainActor @Test func newOrdinaryCommandAfterUndoAbandonsRedoEligibility() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    #expect(try probe.submit(Command(scope: "a", id: "first", fingerprint: "plus-one", kind: .ordinary, delta: 1), host: host) == .accepted)
    #expect(try probe.submit(Command(scope: "a", id: "undo", fingerprint: "minus-one", kind: .undo, delta: -1,
                                     groupID: "first", targetMemberID: "first"), host: host) == .accepted)
    #expect(try probe.snapshot(scope: "a").redoAvailable == true)
    #expect(try probe.submit(Command(scope: "a", id: "new", fingerprint: "plus-four", kind: .ordinary, delta: 4), host: host) == .accepted)
    #expect(try probe.snapshot(scope: "a").redoAvailable == false)
    #expect(try host.value(scope: "a") == 4)
}

@MainActor @Test func failedBoundarySavesNeverMistakeMissingReceiptForRejection() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let command = Command(scope: "a", id: "one", fingerprint: "plus-six", kind: .ordinary, delta: 6)
    let token = try probe.prepare(command)
    probe.fault = .deliveryStarted
    #expect(throws: ProbeError.injectedFailure) { try probe.markDeliveryStarted(token) }
    #expect(try probe.snapshot(scope: "a").phase == .prepared)
    #expect(host.deliveryAttempts == 0)
    try probe.markDeliveryStarted(token)
    host.fault = .beforeSave
    #expect(throws: ProbeError.injectedFailure) { try probe.deliver(token, host: host) }
    #expect(host.deliveryAttempts == 1)
    #expect(try host.lookup(scope: "a", id: "one") == nil)
    #expect(throws: ProbeError.unresolved) { try probe.reconcile(token, host: host) }
    #expect(try probe.snapshot(scope: "a").phase == .unresolved)
    #expect(try host.value(scope: "a") == 0)
    #expect(host.deliveryAttempts == 1)
}

@MainActor @Test func failedAcceptanceRecordReconcilesWithoutRedelivery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let command = Command(scope: "a", id: "one", fingerprint: "plus-eight", kind: .ordinary, delta: 8)
    let token = try probe.prepare(command)
    try probe.markDeliveryStarted(token)
    probe.fault = .acceptance
    #expect(throws: ProbeError.injectedFailure) { try probe.deliver(token, host: host) }
    #expect(try host.value(scope: "a") == 8)
    #expect(host.deliveryAttempts == 1)
    try probe.close()
    let reopened = try RecoveryProbe.open(directory: directory)
    try reopened.recover(host: host)
    #expect(host.deliveryAttempts == 1)
    #expect(try reopened.snapshot(scope: "a").actions.count == 1)
}

@MainActor @Test func failedRejectionRecordCannotCreateAnActionOnReopen() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let command = Command(scope: "a", id: "reject", fingerprint: "no-effect", kind: .ordinary, delta: 10)
    let token = try probe.prepare(command)
    try probe.markDeliveryStarted(token)
    host.nextOutcome = .rejected
    probe.fault = .rejection
    #expect(throws: ProbeError.injectedFailure) { try probe.deliver(token, host: host) }
    #expect(try host.value(scope: "a") == 0)
    try probe.close()
    let reopened = try RecoveryProbe.open(directory: directory)
    try reopened.recover(host: host)
    #expect(try reopened.snapshot(scope: "a").actions.isEmpty)
    #expect(try reopened.snapshot(scope: "a").phase == nil)
    #expect(try reopened.submit(command, host: host) == .rejected)
    #expect(host.deliveryAttempts == 1)
}

@MainActor @Test func acceptedInverseFinalizesAfterReopenWithoutSecondHostDelivery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let first = try RecoveryProbe.open(directory: directory)
    #expect(try first.submit(Command(scope: "a", id: "original", fingerprint: "plus-five", kind: .ordinary,
                                     delta: 5, groupID: "g"), host: host) == .accepted)
    let inverse = Command(scope: "a", id: "inverse", fingerprint: "minus-five", kind: .undo,
                          delta: -5, groupID: "g", targetMemberID: "original")
    let token = try first.prepare(inverse)
    try first.markDeliveryStarted(token)
    try first.deliver(token, host: host)
    first.fault = .finalization
    #expect(throws: ProbeError.injectedFailure) { try first.finalize(token) }
    #expect(try host.value(scope: "a") == 0)
    #expect(host.deliveryAttempts == 2)
    #expect(try first.snapshot(scope: "a").redoAvailable == false)
    try first.close()
    let second = try RecoveryProbe.open(directory: directory)
    #expect(try second.snapshot(scope: "a").phase == .acceptancePending)
    try second.recover(host: host)
    #expect(try second.submit(inverse, host: host) == .accepted)
    #expect(host.deliveryAttempts == 2)
    #expect(try second.snapshot(scope: "a").actions.count == 2)
    #expect(try second.snapshot(scope: "a").redoAvailable == true)
    #expect(try second.snapshot(scope: "a").undoAvailable == false)
}

@MainActor @Test func rejectedInverseOutcomeSaveFailureKeepsRedoFenced() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let first = try RecoveryProbe.open(directory: directory)
    #expect(try first.submit(Command(scope: "a", id: "original", fingerprint: "plus-five", kind: .ordinary,
                                     delta: 5, groupID: "g"), host: host) == .accepted)
    #expect(try first.submit(Command(scope: "a", id: "inverse", fingerprint: "minus-five", kind: .undo,
                                     delta: -5, groupID: "g", targetMemberID: "original"), host: host) == .accepted)
    let compensationID = try #require(first.snapshot(scope: "a").actions.first { $0.kind == .undo }?.id)
    let redo = Command(scope: "a", id: "redo", fingerprint: "stale-redo", kind: .redo, delta: 5,
                       groupID: "g", targetMemberID: "original", compensationActionID: compensationID)
    let token = try first.prepare(redo)
    try first.markDeliveryStarted(token)
    host.nextOutcome = .rejected
    first.fault = .rejection
    #expect(throws: ProbeError.injectedFailure) { try first.deliver(token, host: host) }
    #expect(try first.snapshot(scope: "a").redoAvailable == false)
    try first.close()
    let second = try RecoveryProbe.open(directory: directory)
    #expect(try second.snapshot(scope: "a").redoAvailable == false)
    try second.recover(host: host)
    #expect(try second.snapshot(scope: "a").redoAvailable == false)
    #expect(try second.snapshot(scope: "a").actions.count == 2)
    #expect(try host.value(scope: "a") == 0)
    #expect(host.deliveryAttempts == 3)
}

@MainActor @Test func incompleteInverseMemberPlanIsRefusedBeforeHostDelivery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let original = Command(scope: "a", id: "group", fingerprint: "two-members", kind: .ordinary,
                           groupID: "g", members: [Member(id: "first", delta: 2), Member(id: "second", delta: 3)])
    #expect(try probe.submit(original, host: host) == .accepted)
    let incomplete = Command(scope: "a", id: "bad-inverse", fingerprint: "only-one", kind: .undo,
                             groupID: "g", members: [Member(id: "undo-only", delta: -5, targetMemberID: "second")])
    #expect(throws: ProbeError.invalidGroup) { try probe.submit(incomplete, host: host) }
    let wrongOrder = Command(scope: "a", id: "wrong-order", fingerprint: "wrong-order", kind: .undo,
                             groupID: "g", members: [Member(id: "undo-first", delta: -2, targetMemberID: "first"),
                                                    Member(id: "undo-second", delta: -3, targetMemberID: "second")])
    #expect(throws: ProbeError.invalidGroup) { try probe.submit(wrongOrder, host: host) }
    #expect(host.deliveryAttempts == 1)
    #expect(try host.value(scope: "a") == 5)
    #expect(try probe.snapshot(scope: "a").undoAvailable)
}

@MainActor @Test func unresolvedScopeDoesNotStopIndependentAcceptedRecovery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let first = try RecoveryProbe.open(directory: directory)
    let unavailable = Command(scope: "a", id: "missing", fingerprint: "missing-receipt", kind: .ordinary, delta: 1)
    let a = try first.prepare(unavailable)
    try first.markDeliveryStarted(a)
    let accepted = Command(scope: "b", id: "accepted", fingerprint: "plus-four", kind: .ordinary, delta: 4)
    let b = try first.prepare(accepted)
    try first.markDeliveryStarted(b)
    _ = try host.apply(accepted)
    try first.close()
    let reopened = try RecoveryProbe.open(directory: directory)
    #expect(throws: ProbeError.unresolved) { try reopened.recover(host: host) }
    #expect(try reopened.snapshot(scope: "a").phase == .unresolved)
    #expect(try reopened.snapshot(scope: "b").phase == nil)
    #expect(try reopened.snapshot(scope: "b").actions.count == 1)
    #expect(try host.value(scope: "b") == 4)
    #expect(host.deliveryAttempts == 1)
}

@MainActor @Test func redoRequiresIdentityOfLatestCompensatingAction() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { cleanup(directory) }
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let original = Command(scope: "a", id: "original", fingerprint: "plus-three", kind: .ordinary,
                           delta: 3, groupID: "g")
    #expect(try probe.submit(original, host: host) == .accepted)
    let undo = Command(scope: "a", id: "undo-1", fingerprint: "minus-three", kind: .undo,
                       delta: -3, groupID: "g", targetMemberID: "original")
    #expect(try probe.submit(undo, host: host) == .accepted)
    let unlinked = Command(scope: "a", id: "unlinked-redo", fingerprint: "missing-compensation", kind: .redo,
                           delta: 3, groupID: "g", targetMemberID: "original")
    #expect(throws: ProbeError.invalidGroup) { try probe.submit(unlinked, host: host) }
    #expect(try host.value(scope: "a") == 0)
    #expect(host.deliveryAttempts == 2)
    let firstCompensation = try #require(probe.snapshot(scope: "a").actions.first { $0.kind == .undo }?.id)
    try probe.close()
    let reopened = try RecoveryProbe.open(directory: directory)
    let linked = Command(scope: "a", id: "redo-1", fingerprint: "linked-redo", kind: .redo,
                         delta: 3, groupID: "g", targetMemberID: "original",
                         compensationActionID: firstCompensation)
    #expect(try reopened.submit(linked, host: host) == .accepted)
    #expect(try reopened.snapshot(scope: "a").actions.first { $0.kind == .redo }?.compensationActionID == firstCompensation)
    #expect(try host.lookup(scope: "a", id: "redo-1")?.compensationActionIDs == [firstCompensation])
    let secondUndo = Command(scope: "a", id: "undo-2", fingerprint: "second-compensation", kind: .undo,
                             delta: -3, groupID: "g", targetMemberID: "original")
    #expect(try reopened.submit(secondUndo, host: host) == .accepted)
    let secondCompensation = try #require(reopened.snapshot(scope: "a").actions.first { $0.memberID == "undo-2" }?.id)
    #expect(secondCompensation != firstCompensation)
    let stale = Command(scope: "a", id: "stale-redo", fingerprint: "old-link", kind: .redo,
                        delta: 3, groupID: "g", targetMemberID: "original",
                        compensationActionID: firstCompensation)
    #expect(throws: ProbeError.invalidGroup) { try reopened.submit(stale, host: host) }
    let current = Command(scope: "a", id: "redo-2", fingerprint: "new-link", kind: .redo,
                          delta: 3, groupID: "g", targetMemberID: "original",
                          compensationActionID: secondCompensation)
    #expect(try reopened.submit(current, host: host) == .accepted)
    #expect(try reopened.snapshot(scope: "a").actions.first { $0.memberID == "redo-2" }?.compensationActionID == secondCompensation)
    #expect(try host.value(scope: "a") == 3)
    #expect(host.deliveryAttempts == 5)
}
