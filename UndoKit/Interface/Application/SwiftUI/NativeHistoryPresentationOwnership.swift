// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

#if canImport(SwiftUI) && (canImport(AppKit) || canImport(UIKit))
import SwiftUI

/// Platform hosts implement mounting and native visibility; this policy owns only
/// which weakly-held host may present one editor and in what order hosts wait.
@MainActor protocol NativeHistoryPresentationHost: AnyObject {
    var canMountPresentedEditor: Bool { get }
    func mountPresentedEditor()
    func unmountPresentedEditor()
    func showUnavailableEditor()
}

@MainActor final class NativeHistoryPresentationOwnership {
    private weak var current: (any NativeHistoryPresentationHost)?
    private var waiting: [WeakHost] = []

    private final class WeakHost {
        weak var value: (any NativeHistoryPresentationHost)?
        init(_ value: any NativeHistoryPresentationHost) { self.value = value }
    }

    func isCurrent(_ host: any NativeHistoryPresentationHost) -> Bool { current === host }

    func attach(_ host: any NativeHistoryPresentationHost) {
        pruneWaiters()
        if current == nil { promoteNextWaiter() }
        if current === host { return }
        guard current == nil else {
            if !waiting.contains(where: { $0.value === host }) { waiting.append(WeakHost(host)) }
            return
        }
        guard host.canMountPresentedEditor else {
            host.showUnavailableEditor()
            return
        }
        current = host
        host.mountPresentedEditor()
    }

    func detach(_ host: any NativeHistoryPresentationHost) {
        waiting.removeAll { $0.value == nil || $0.value === host }
        guard current === host else {
            if current == nil { promoteNextWaiter() }
            return
        }
        current = nil
        host.unmountPresentedEditor()
        promoteNextWaiter()
    }

    private func pruneWaiters() { waiting.removeAll { $0.value == nil } }

    private func promoteNextWaiter() {
        pruneWaiters()
        while !waiting.isEmpty {
            let candidate = waiting.removeFirst().value
            guard let candidate else { continue }
            if candidate.canMountPresentedEditor {
                current = candidate
                candidate.mountPresentedEditor()
                return
            }
            candidate.showUnavailableEditor()
        }
    }
}
#endif
