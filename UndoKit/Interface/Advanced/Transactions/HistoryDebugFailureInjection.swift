// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

#if DEBUG
struct HistoryInjectedFinalizationIdentity: Sendable {
    let owner: ObjectIdentifier
    let scope: UUID
    let command: UUID
}

extension HistoryEngine {
    @TaskLocal static var injectedFinalizationIdentity: HistoryInjectedFinalizationIdentity?

    /// Submits a Debug demonstration with the production accepted-finalization save
    /// boundary refusing writes. Normal rollback and suspension rules apply.
    /// The host can already have durably accepted the effect; close and reopen
    /// afterwards to reconcile its authoritative receipt. Refuses a busy engine;
    /// this seam is for controlled, quiescent demonstrations. Only this Command's
    /// finalization in this engine fails, including if a later request joins the same drain task
    /// or another independent working copy preserves the same scope and Command IDs.
    /// This injection is absent from Release builds and is not a
    /// storage configuration or an abrupt-termination qualification mechanism.
    @MainActor public func submitWithInjectedFinalizationFailure(_ command: HistoryCommand) async -> HistoryResult {
        guard !snapshot.hasPending else {
            return .failure(HistoryFailure(.busy, stage: .admission, disposition: .usable))
        }
        let identity = HistoryInjectedFinalizationIdentity(
            owner: ObjectIdentifier(history),
            scope: history.scope, command: command.id)
        return await Self.$injectedFinalizationIdentity.withValue(identity) {
            await HistoryScopeStorage.$failSaveAt.withValue(.acceptedFinalization) {
                await self.submit(command)
            }
        }
    }
}
#endif
