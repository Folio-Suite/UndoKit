// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import UndoKit

/// The domain framework exposes the public type identity it sees from UndoKit.
/// The app compares this with its own import to detect a second loaded runtime.
@MainActor
public func consumerDomainHistoryStoreTypeIdentity() -> ObjectIdentifier {
    ObjectIdentifier(HistoryStore.self)
}
