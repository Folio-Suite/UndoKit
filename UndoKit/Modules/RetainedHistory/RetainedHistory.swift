// SPDX-FileCopyrightText: 2026 the Folio Project
// SPDX-License-Identifier: MIT

import CoreData
import Foundation

// MARK: - Cooperation with transactions

/// The transaction module exposes only the activity needed to admit retained-history work.
@MainActor protocol HistoryRetainedActivity: AnyObject {
    var snapshot: HistorySnapshot { get }
    var isExecuting: Bool { get }
    var isActive: Bool { get }
    var closing: Bool { get }
    var closed: Bool { get }
    func requireIdle() throws
}

/// Lifecycle transitions consult protection without gaining access to the plan registry.
@MainActor protocol HistoryRecoveryProtection: AnyObject {
    var hasRecoveryPlans: Bool { get }
    func invalidateRecoveryPlans()
}

// MARK: - Scope ownership

/// Owns checkpoints, reconstruction, holds and consolidation for one open scope.
/// All plan registration and invalidation is local to this owner.
@MainActor final class RetainedHistory: HistoryRecoveryProtection {
    let history: HistoryScopeStorage
    let activity: any HistoryRetainedActivity
    private var recoveryPlans: [UUID: HistoryRecoveryPlan] = [:]

    var store: HistoryStore { history.store }
    var scope: UUID { history.scope }
    var limits: HistoryLimits { history.limits }
    var context: NSManagedObjectContext { history.context }
    var snapshot: HistorySnapshot { activity.snapshot }

    init(history: HistoryScopeStorage, activity: any HistoryRetainedActivity) {
        self.history = history
        self.activity = activity
    }

    // MARK: - Recovery Plan protection

    var hasRecoveryPlans: Bool { !recoveryPlans.isEmpty }
    var recoveryPlanCount: Int { recoveryPlans.count }
    var activeRecoveryPlans: [HistoryRecoveryPlan] { Array(recoveryPlans.values) }

    func registerRecoveryPlan(_ plan: HistoryRecoveryPlan) { recoveryPlans[plan.id] = plan }
    func containsRecoveryPlan(_ plan: HistoryRecoveryPlan) -> Bool { recoveryPlans[plan.id] == plan }
    func releaseRecoveryPlan(_ plan: HistoryRecoveryPlan) { recoveryPlans.removeValue(forKey: plan.id) }
    func invalidateRecoveryPlans() { recoveryPlans.removeAll() }
}
