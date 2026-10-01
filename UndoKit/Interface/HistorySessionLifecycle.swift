// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

extension HistoryEngine {
    // MARK: - Copy and closure

    /// Copies one idle and reconciled history store to a separate closed SQLite file.
    /// The host captures matching domain state and resources and registers the copy independently.
    public func copyStore(to destination: URL) throws {
        guard store.engines.count == 1 else {
            throw HistoryFailure(.busy, stage: .admission, disposition: .usable)
        }
        try store.copyIdle(to: destination)
    }

    /// Stops admission, rejects queued requests and waits for active delivery.
    /// A convenience-opened session also closes its physical store.
    public func close() async throws {
        let wasClosed = transaction.closed
        try await transaction.close(protection: retained)
        if !wasClosed { store.engines.removeValue(forKey: scope) }
        if ownsConvenienceStore && !store.closed && (wasClosed || !store.closing) {
            try await store.close()
        }
    }

    func beginClosing() { transaction.beginClosing(protection: retained) }
}
