// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

/// Exact opaque prepared evidence embedded in the current field journal.
enum HistoryPreparedEvidence {
    struct Payload: Codable {
        let family: String
        let version: Int
        let data: Data
        init(_ payload: HistoryPayload) {
            family = payload.family
            version = payload.version
            data = payload.data
        }
        var value: HistoryPayload { HistoryPayload(family: family, version: version, data: data) }
    }
    struct Member: Codable {
        let id: UUID
        let payload: Payload
        init(_ member: HistoryMember) {
            id = member.id
            payload = Payload(member.payload)
        }
        var value: HistoryMember { HistoryMember(id: id, payload: payload.value) }
    }
    struct Command: Codable {
        let id: UUID
        let fingerprint: Data
        let members: [Member]
        let restorationOrigin: UUID?
        let presentation: Payload?
        let expectedGeneration: UUID?
        init(_ command: HistoryCommand) {
            id = command.id
            fingerprint = command.fingerprint
            members = command.members.map(Member.init)
            restorationOrigin = command.restorationOrigin
            presentation = command.presentation.map(Payload.init)
            expectedGeneration = command.expectedGeneration
        }
        var value: HistoryCommand {
            HistoryCommand(
                id: id, fingerprint: fingerprint, members: members.map(\.value),
                restorationOrigin: restorationOrigin, presentation: presentation?.value,
                expectedGeneration: expectedGeneration)
        }
    }
}
