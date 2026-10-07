import Foundation

/// What the evaluator needs to know about one local account. Gathered from the
/// directory and the disk by `AccountInspector`, or built by hand in tests.
struct AccountFacts: Equatable {
    let name: String
    let createdAt: Date?
    let lastLogin: Date?
    let isAdmin: Bool
    let hasSecureToken: Bool
    let isVolumeOwner: Bool
}

/// Who must never be deleted, whatever the age policy says.
struct AccountProtection {
    /// Names never deleted. Matched case-insensitively.
    let exclusions: Set<String>
    /// When false (the default), members of the admin group are never deleted.
    let deleteAdmins: Bool
    /// Admins that may be deleted while `deleteAdmins` is false. Exclusions win.
    let deletableAdmins: Set<String>

    init(exclusions: [String], deleteAdmins: Bool = false, deletableAdmins: [String] = []) {
        self.exclusions = Set(exclusions.map { $0.lowercased() })
        self.deleteAdmins = deleteAdmins
        self.deletableAdmins = Set(deletableAdmins.map { $0.lowercased() })
    }

    func isExcluded(_ name: String) -> Bool { exclusions.contains(name.lowercased()) }
    func isDeletableAdmin(_ name: String) -> Bool { deletableAdmins.contains(name.lowercased()) }
}

enum DeletionDecision: Equatable {
    case delete(String)
    case keep(String)

    var shouldDelete: Bool {
        if case .delete = self { return true }
        return false
    }

    var reason: String {
        switch self {
        case .delete(let reason), .keep(let reason): return reason
        }
    }
}

/// The one place that decides whether an account goes. Every path that deletes
/// an account (the age policy, deferred deletes, orphan cleanup, force mode)
/// asks this first, so the protections below cannot be skipped.
enum DeletionEvaluator {

    /// - Parameters:
    ///   - adminVolumeOwnersRemaining: admin volume owners on the boot volume
    ///     other than this account. A volume owner is kept when deleting it would
    ///     leave none, because the disk could no longer be unlocked or updated.
    static func evaluate(
        _ account: AccountFacts,
        policy: DeletionPolicy,
        protection: AccountProtection,
        adminVolumeOwnersRemaining: Int,
        now: Date = Date()
    ) -> DeletionDecision {
        if protection.isExcluded(account.name) {
            return .keep("excluded")
        }

        if account.isAdmin && !protection.deleteAdmins && !protection.isDeletableAdmin(account.name) {
            return .keep("member of the admin group (DeleteAdmins is off)")
        }

        if account.isVolumeOwner && adminVolumeOwnersRemaining == 0 {
            return .keep("last admin volume owner on the boot volume")
        }

        if account.hasSecureToken && account.isAdmin && adminVolumeOwnersRemaining == 0 {
            return .keep("last admin SecureToken holder")
        }

        if policy.duration < 0 {
            return .keep("policy never deletes")
        }

        // An account whose creation date cannot be read is treated as new.
        guard let createdAt = account.createdAt else {
            return .keep("creation date unknown")
        }

        let threshold: TimeInterval = policy.forceTermDeletion ? 0 : TimeInterval(policy.duration)
        let creationAge = now.timeIntervalSince(createdAt)
        let days = Int(threshold / 86_400)

        switch policy.strategy {
        case .creationOnly:
            if creationAge >= threshold {
                return .delete("created \(Int(creationAge / 86_400))d ago (threshold \(days)d, creation only)")
            }
            return .keep("created \(Int(creationAge / 86_400))d ago (threshold \(days)d, creation only)")

        case .loginAndCreation:
            // No recorded login counts as "never logged in", which is older than any threshold.
            let loginAge = account.lastLogin.map { now.timeIntervalSince($0) } ?? .infinity
            let loginText = account.lastLogin == nil ? "never" : "\(Int(loginAge / 86_400))d ago"
            if creationAge >= threshold && loginAge >= threshold {
                return .delete("created \(Int(creationAge / 86_400))d ago, last login \(loginText) (threshold \(days)d)")
            }
            return .keep("created \(Int(creationAge / 86_400))d ago, last login \(loginText) (threshold \(days)d)")
        }
    }
}
