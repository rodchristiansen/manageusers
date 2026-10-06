import Foundation

/// Machine settings for manageusers in the `com.github.manageusers` domain.
///
/// Values are read with `CFPreferencesCopyAppValue`, so a key forced by a configuration
/// profile wins over `/Library/Preferences/com.github.manageusers.plist`, which wins over the
/// built-in policy. A command-line flag given for this run wins over all of them.
struct ManageUsersPreferences {
    static let domain = "com.github.manageusers"

    enum Key {
        /// Inactivity threshold in days; replaces the area-derived duration.
        static let deletionDays = "DeletionDays"
        /// `login-and-creation` or `creation-only`; replaces the area-derived strategy.
        static let deletionStrategy = "DeletionStrategy"
        /// Accounts never deleted, in addition to the built-in exclusions.
        static let additionalExclusions = "AdditionalExclusions"
    }

    typealias Reader = (String) -> Any?

    let read: Reader

    static var system: ManageUsersPreferences {
        ManageUsersPreferences { key in
            CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        }
    }

    /// The flag for this run, else the setting; nil when neither is set or the value is not positive.
    func deletionDays(flag: Int?) -> Int? {
        if let flag, flag > 0 { return flag }
        let value: Int?
        switch read(Key.deletionDays) {
        case let number as Int: value = number
        case let text as String: value = Int(text.trimmingCharacters(in: .whitespaces))
        default: value = nil
        }
        guard let value, value > 0 else { return nil }
        return value
    }

    /// The flag for this run, else the setting; nil when neither names a known strategy.
    func deletionStrategy(flag: String?) -> DeletionStrategy? {
        if let flag, let strategy = DeletionStrategy(name: flag) { return strategy }
        guard let name = read(Key.deletionStrategy) as? String else { return nil }
        return DeletionStrategy(name: name)
    }

    func additionalExclusions() -> [String] {
        (read(Key.additionalExclusions) as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension DeletionStrategy {
    init?(name: String) {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "login-and-creation": self = .loginAndCreation
        case "creation-only": self = .creationOnly
        default: return nil
        }
    }
}

/// Reads a value from another app's domain through CFPreferences, so a value a
/// configuration profile forces counts as well as the one on disk.
func managedStringPreference(_ key: String, domain: String) -> String? {
    guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else { return nil }
    if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
    return "\(value)"
}
