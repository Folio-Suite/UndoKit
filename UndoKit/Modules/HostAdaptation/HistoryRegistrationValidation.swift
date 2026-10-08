// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import Foundation

enum HistoryRegistrationValidation {
    static func validate(operation: String) throws {
        guard !operation.isEmpty else { throw invalidRegistration() }
    }

    static func validate<Value>(_ codec: HistoryCodec<Value>, version: Int,
                                older: [Int: HistoryCodec<Value>]) throws {
        guard version > 0, !codec.identifier.isEmpty,
              older.allSatisfy({ $0.key > 0 && $0.key < version && !$0.value.identifier.isEmpty }) else {
            throw invalidRegistration()
        }
    }

    private static func invalidRegistration() -> HistoryFailure {
        HistoryFailure(.invalidInput, stage: .admission, disposition: .usable)
    }
}
