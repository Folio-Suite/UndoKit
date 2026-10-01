// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

extension HistoryEngine {
    var store: HistoryStore { history.store }
    var scope: UUID { history.scope }
    var limits: HistoryLimits { history.limits }
    var context: NSManagedObjectContext { history.context }
}
