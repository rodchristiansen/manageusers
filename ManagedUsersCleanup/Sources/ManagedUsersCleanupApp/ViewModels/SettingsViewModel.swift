//
//  SettingsViewModel.swift
//  Managed Users Cleanup
//
//  manageusers' preferences for the Prefs tab. Values are read the way the
//  root tool reads them; keys a profile manages are shown gray and never
//  written. Other edits are held in the window until Save, which asks for an
//  administrator and then writes them through the privileged helper.
//

import Foundation
import ManagedUsersCleanupXPC

/// How deletions are decided when no strategy is set: by the area rules.
enum StrategyChoice: String, CaseIterable, Identifiable, Equatable {
    case areaDefault = ""
    case loginAndCreation = "login-and-creation"
    case creationOnly = "creation-only"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .areaDefault: "Area default"
        case .loginAndCreation: "Creation and last login"
        case .creationOnly: "Creation only"
        }
    }
}

/// The editable preferences, as the window holds them.
struct PreferenceSnapshot: Equatable {
    /// Days; 0 means "not set", so the area rules decide.
    var deletionDays = 0
    var strategy: StrategyChoice = .areaDefault
    var additionalExclusions: [String] = []
    var deleteAdmins = false
    var deletableAdmins: [String] = []
}

/// One write the helper performs.
enum PreferenceWrite: Equatable {
    case bool(UsersPreferenceKey, Bool)
    case int(UsersPreferenceKey, Int)
    case string(UsersPreferenceKey, String)
    case array(UsersPreferenceKey, [String])
    case remove(UsersPreferenceKey)
}

@Observable
@MainActor
final class SettingsViewModel {

    // MARK: - Values

    var deletionDays = 0
    var strategy: StrategyChoice = .areaDefault
    /// Accounts never deleted, edited as a list.
    var additionalExclusions: [String] = []
    var deleteAdmins = false
    var deletableAdminsText = ""

    private(set) var managedKeys: Set<String> = []

    // MARK: - Save Status

    enum SaveStatus: Equatable {
        case idle, saving, saved, failed(String)
    }
    private(set) var saveStatus: SaveStatus = .idle

    // MARK: - Saving

    private let source: PreferenceSource
    private let authorizer: AdminAuthorizing
    private weak var writer: PreferenceWriting?
    private var saved = PreferenceSnapshot()

    init(source: PreferenceSource = SystemPreferenceSource(), authorizer: AdminAuthorizing = AdminAuthorization()) {
        self.source = source
        self.authorizer = authorizer
    }

    func configure(client: PreferenceWriting) {
        writer = client
    }

    /// True when every key the window edits is set by a profile, so the
    /// window is read-only and offers no Save.
    var isFullyManaged: Bool {
        UsersPreferenceKey.allCases.allSatisfy { managedKeys.contains($0.rawValue) }
    }

    /// The writes Save would perform: edits to keys no profile manages.
    var pendingWrites: [PreferenceWrite] {
        Self.writes(from: saved, to: current, managed: managedKeys)
    }

    var hasUnsavedChanges: Bool { !pendingWrites.isEmpty }

    /// True when a profile forces at least one of manageusers' keys.
    var hasManagedSettings: Bool { !managedKeys.isEmpty }

    func isManaged(_ key: UsersPreferenceKey) -> Bool {
        managedKeys.contains(key.rawValue)
    }

    // MARK: - Load

    func load() {
        managedKeys = Set(UsersPreferenceKey.allCases.map(\.rawValue).filter(source.isManaged))
        let snapshot = Self.read(from: source)
        apply(snapshot)
        saved = snapshot
    }

    /// Puts every field back to the stored value, discarding unsaved edits.
    func revert() {
        apply(saved)
        if case .failed = saveStatus { saveStatus = .idle }
    }

    /// Reads each value with the meaning the tool gives it.
    static func read(from source: PreferenceSource) -> PreferenceSnapshot {
        var snapshot = PreferenceSnapshot()
        if let days = intValue(source.value(forKey: UsersPreferenceKey.deletionDays.rawValue)), days > 0 {
            snapshot.deletionDays = days
        }
        if let raw = source.value(forKey: UsersPreferenceKey.deletionStrategy.rawValue) as? String {
            snapshot.strategy = StrategyChoice(rawValue: raw.lowercased()) ?? .areaDefault
        }
        snapshot.additionalExclusions = listValue(source.value(forKey: UsersPreferenceKey.additionalExclusions.rawValue))
        snapshot.deleteAdmins = boolValue(source.value(forKey: UsersPreferenceKey.deleteAdmins.rawValue))
        snapshot.deletableAdmins = listValue(source.value(forKey: UsersPreferenceKey.deletableAdmins.rawValue))
        return snapshot
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["1", "true", "yes"].contains(string.lowercased()) }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func listValue(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        if let string = value as? String { return parseNames(string) }
        return []
    }

    private func apply(_ snapshot: PreferenceSnapshot) {
        deletionDays = snapshot.deletionDays
        strategy = snapshot.strategy
        additionalExclusions = snapshot.additionalExclusions
        deleteAdmins = snapshot.deleteAdmins
        deletableAdminsText = snapshot.deletableAdmins.joined(separator: ", ")
    }

    private var current: PreferenceSnapshot {
        PreferenceSnapshot(
            deletionDays: max(0, deletionDays),
            strategy: strategy,
            additionalExclusions: additionalExclusions,
            deleteAdmins: deleteAdmins,
            deletableAdmins: Self.parseNames(deletableAdminsText)
        )
    }

    // MARK: - Exclusion List

    /// Adds every name in `text` (commas and spaces separate several) that is
    /// not already on the list, ignoring case. Returns the names added.
    @discardableResult
    func addExclusions(from text: String) -> [String] {
        guard !isManaged(.additionalExclusions) else { return [] }
        let existing = Set(additionalExclusions.map { $0.lowercased() })
        let added = Self.parseNames(text).filter { !existing.contains($0.lowercased()) }
        if !added.isEmpty { additionalExclusions += added }
        return added
    }

    func removeExclusions(_ names: Set<String>) {
        guard !isManaged(.additionalExclusions), !names.isEmpty else { return }
        additionalExclusions.removeAll { names.contains($0) }
    }

    /// Splits a names field on commas and whitespace, keeping the first
    /// occurrence of each name.
    static func parseNames(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Save

    /// The writes that take the stored preferences from `old` to `new`,
    /// skipping managed keys. Unset and empty values remove the key, which is
    /// how the tool reads "use the default".
    static func writes(from old: PreferenceSnapshot, to new: PreferenceSnapshot, managed: Set<String>) -> [PreferenceWrite] {
        var writes: [PreferenceWrite] = []
        func allowed(_ key: UsersPreferenceKey) -> Bool { !managed.contains(key.rawValue) }

        if old.deletionDays != new.deletionDays, allowed(.deletionDays) {
            writes.append(new.deletionDays > 0 ? .int(.deletionDays, new.deletionDays) : .remove(.deletionDays))
        }
        if old.strategy != new.strategy, allowed(.deletionStrategy) {
            writes.append(new.strategy == .areaDefault ? .remove(.deletionStrategy) : .string(.deletionStrategy, new.strategy.rawValue))
        }
        if old.additionalExclusions != new.additionalExclusions, allowed(.additionalExclusions) {
            writes.append(new.additionalExclusions.isEmpty ? .remove(.additionalExclusions) : .array(.additionalExclusions, new.additionalExclusions))
        }
        if old.deleteAdmins != new.deleteAdmins, allowed(.deleteAdmins) {
            writes.append(new.deleteAdmins ? .bool(.deleteAdmins, true) : .remove(.deleteAdmins))
        }
        if old.deletableAdmins != new.deletableAdmins, allowed(.deletableAdmins) {
            writes.append(new.deletableAdmins.isEmpty ? .remove(.deletableAdmins) : .array(.deletableAdmins, new.deletableAdmins))
        }
        return writes
    }

    /// Asks for an administrator, then writes the pending edits through the
    /// helper with that one authorization. Cancelling the prompt leaves the
    /// edits in place, unsaved, without an error.
    func save() async {
        guard let writer else { return }
        let target = current
        let pending = Self.writes(from: saved, to: target, managed: managedKeys)
        guard !pending.isEmpty else { return }

        guard let grant = authorizer.authorize() else { return }
        defer { grant.release() }

        saveStatus = .saving
        var failed: [String] = []
        var applied = saved
        for write in pending {
            if await writer.perform(write, authorization: grant.externalForm) {
                Self.record(write, from: target, into: &applied)
            } else {
                failed.append(write.key.rawValue)
            }
        }
        saved = applied

        if failed.isEmpty {
            saveStatus = .saved
            try? await Task.sleep(for: .seconds(2.5))
            if saveStatus == .saved { saveStatus = .idle }
        } else {
            saveStatus = .failed("Could not save \(failed.joined(separator: ", ")): the helper refused or is not available")
        }
    }

    /// Copies the one value a successful write stored from `target` into
    /// `snapshot`, so a failed write stays pending for the next Save.
    private static func record(_ write: PreferenceWrite, from target: PreferenceSnapshot, into snapshot: inout PreferenceSnapshot) {
        switch write.key {
        case .deletionDays: snapshot.deletionDays = target.deletionDays
        case .deletionStrategy: snapshot.strategy = target.strategy
        case .additionalExclusions: snapshot.additionalExclusions = target.additionalExclusions
        case .deleteAdmins: snapshot.deleteAdmins = target.deleteAdmins
        case .deletableAdmins: snapshot.deletableAdmins = target.deletableAdmins
        }
    }
}

extension PreferenceWrite {
    var key: UsersPreferenceKey {
        switch self {
        case .bool(let key, _), .int(let key, _), .string(let key, _), .array(let key, _), .remove(let key): key
        }
    }
}
