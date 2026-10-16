// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

extension HistorySession {
    func nativeStateChanged(
        issue: HistoryFailure?, requiresDraftDecision: Bool,
        hasLiveUndo: Bool = false, hasLiveRedo: Bool = false
    ) {
        nativeIssue = issue
        self.requiresDraftDecision = requiresDraftDecision
        liveUndo = hasLiveUndo
        liveRedo = hasLiveRedo
        refreshStatus()
    }

    func refreshStatus() {
        let phase: HistorySessionPhase
        if closed {
            phase = .closed
        } else if closeRequested && issue == nil {
            phase = .closing
        } else if opening {
            phase = .opening
        } else if issue != nil || nativeIssue != nil {
            phase = .blocked
        } else if snapshot.isSuspended {
            phase = .suspended
        } else if snapshot.hasPending || engine?.transaction.reconciling == true {
            phase = .busy
        } else {
            phase = .ready
        }
        let ready = phase == .ready && !requiresDraftDecision
        let next = HistorySessionStatus(
            phase: phase,
            canUndo: ready && (snapshot.canUndo || liveUndo), canRedo: ready && (snapshot.canRedo || liveRedo),
            issue: nativeIssue ?? issue, requiresDraftDecision: requiresDraftDecision)
        guard next != status else { return }
        status = next
        nativeCoordinator.publish(status: next)
        for observer in Array(observers.values) { observer(next) }
        collection?.changed()
    }
}
