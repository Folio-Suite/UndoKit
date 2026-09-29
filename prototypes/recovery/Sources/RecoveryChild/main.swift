// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT
import Darwin
import Foundation
import RecoveryProbe

@MainActor func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else { exit(64) }
    let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let mode = arguments[2]
    let host = try HostStore.open(directory: directory)
    let probe = try RecoveryProbe.open(directory: directory)
    let command = Command(scope: "killed", id: "child-one", fingerprint: "child-add-seven", kind: .ordinary, delta: 7)
    let token = try probe.prepare(command)
    if mode == "afterPrepare" { kill(getpid(), SIGKILL) }
    try probe.markDeliveryStarted(token)
    if mode == "afterDelivery" { kill(getpid(), SIGKILL) }
    _ = try host.apply(command)
    if mode == "afterHostAcceptance" { kill(getpid(), SIGKILL) }
    try probe.reconcile(token, host: host)
    if mode == "afterAcceptanceRecord" { kill(getpid(), SIGKILL) }
    _ = try probe.finalize(token)
    if mode == "afterFinalization" { kill(getpid(), SIGKILL) }
    exit(64)
}

do { try run() } catch { fputs("RecoveryChild: \(error)\n", stderr); exit(1) }
