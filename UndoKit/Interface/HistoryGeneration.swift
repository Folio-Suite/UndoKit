// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

extension HistoryEngine {
    /// Explicitly omit this scope's retained history after the host has adopted
    /// coherent current state. All transactions must be settled. Other scopes,
    /// native Document Versions, backups, and host resources are untouched.
    /// - Parameters:
    ///   - baseline: Host-authored current state for the new generation.
    ///   - resources: Opaque objects required by that state.
    /// - Returns: New generation ID. Subsequent submissions, Undo and Redo must
    ///   bind to this generation before host delivery.
    /// - Throws: Admission, storage or capacity failure. No generation is
    ///   retired when admission fails.
    @discardableResult public func clearHistory(
        adopting baseline: HistoryPayload, resources: [HistoryObjectReference] = []
    ) throws -> UUID {
        try transaction.clearHistory(adopting: baseline, resources: resources, protection: retained)
    }

    /// Acknowledge lost continuity from an irrecoverable unresolved outcome.
    /// The entire failed store is first copied to the caller's absent quarantine
    /// URL; reset proceeds only after that copy succeeds. The host must establish
    /// current domain reality independently before calling this method.
    /// - Parameters:
    ///   - baseline: Host-confirmed coherent current state.
    ///   - resources: Opaque objects required by that state.
    ///   - destination: Absent URL for the failed store copy.
    /// - Returns: New generation ID requiring client reattachment.
    /// - Throws: Busy without unresolved evidence, failed quarantine copy,
    ///   invalid input, capacity or storage failure.
    @discardableResult public func resetUnresolvedHistory(
        adopting baseline: HistoryPayload, resources: [HistoryObjectReference] = [],
        quarantineAt destination: URL
    ) throws -> UUID {
        try transaction.resetUnresolvedHistory(adopting: baseline, resources: resources,
                                              quarantineAt: destination, protection: retained)
    }

}
