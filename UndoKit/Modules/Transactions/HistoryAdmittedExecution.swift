// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

extension HistoryTransactionCoordinator {
    func executeReserved(_ request: Request, reservation: Reservation) async -> HistoryResult {
        #if DEBUG
        if reservation.injectFinalizationFailure, case .command(let command) = request {
            let identity = HistoryInjectedFinalizationIdentity(
                owner: ObjectIdentifier(history),
                scope: scope, command: command.id)
            return await HistoryEngine.$injectedFinalizationIdentity.withValue(identity) {
                await HistoryScopeStorage.$failSaveAt.withValue(.acceptedFinalization) {
                    await executeAdmitted(request, reservation: reservation)
                }
            }
        }
        #endif
        return await executeAdmitted(request, reservation: reservation)
    }

    func executeAdmitted(_ request: Request, reservation: Reservation) async -> HistoryResult {
        if let failure = admissionParticipantFailure() { return failure }
        guard reservation.generation == snapshot.generation else {
            return .failure(HistoryFailure(.identityConflict, stage: .admission, disposition: .usable))
        }
        var prerequisite: HistoryResult?
        if let id = reservation.prerequisite, let participant {
            let callbacks = HistoryHostCallbackContext.activeTransactions.union([ObjectIdentifier(self)])
            prerequisite = await HistoryStore.$deliveringStores.withValue(
                HistoryStore.deliveringStores.union([ObjectIdentifier(store)])
            ) {
                await HistoryHostCallbackContext.$activeTransactions.withValue(callbacks) {
                    await participant.settlePrerequisite(id) { command in
                        await self.execute(.command(command))
                    }
                }
            }
            if let prerequisite, let stop = dependentResult(prerequisite, request: request) { return stop }
        }
        if case .settle = request { return prerequisite ?? .rejected }
        if let failure = admissionParticipantFailure() { return failure }
        return await execute(request)
    }

    private func dependentResult(_ prerequisite: HistoryResult, request: Request) -> HistoryResult? {
        switch prerequisite {
        case .accepted: return nil
        case .rejected:
            if case .settle = request { return prerequisite }
            return .failure(HistoryFailure(.prerequisiteRejected, stage: .admission, disposition: .usable))
        case .failure(let failure):
            if case .settle = request { return prerequisite }
            // The prerequisite may have effects; this dependent request did not.
            return .failure(
                HistoryFailure(
                    failure.cause, stage: .admission,
                    disposition: failure.disposition, underlyingDescription: failure.underlyingDescription))
        }
    }

    private func admissionParticipantFailure() -> HistoryResult? {
        guard let failure = participant?.admissionFailure() else { return nil }
        return .failure(
            HistoryFailure(
                failure.cause, stage: .admission,
                disposition: failure.disposition, underlyingDescription: failure.underlyingDescription))
    }
}
