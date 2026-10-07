//
//  SettingsViewModel.swift
//  Managed Users Cleanup
//
//  manageusers' preferences for the Prefs tab. Values are read the way the
//  root tool reads them; keys a profile manages are shown locked and never
//  written. Edits auto-save through the privileged helper.
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

    var deletionDays = 0 { didSet { scheduleAutoSave() } }
    var strategy: StrategyChoice = .areaDefault { didSet { scheduleAutoSave() } }
    var additionalExclusionsText = "" { didSet { scheduleAutoSave() } }
    var deleteAdmins = false { didSet { scheduleAutoSave() } }
    var deletableAdminsText = "" { didSet { scheduleAutoSave() } }

    private(set) var managedKeys: Set<String> = []

    // MARK: - Save Status

    enum SaveStatus: Equatable {
        case idle, saving, saved, failed(String)
    }
    private(set) var saveStatus: SaveStatus = .idle

    // MARK: - Auto-Save

    private let source: PreferenceSource
    private var xpcClient: XPCClient?
    private var autoSaveTask: Task<Void, Never>?
    private var isLoading = false
    private var saved = PreferenceSnapshot()

    init(source: PreferenceSource = SystemPreferenceSource()) {
        self.source = source
    }

    func configure(client: XPCClient) {
        xpcClient = client
    }

    private func scheduleAutoSave() {
        guard !isLoading, xpcClient != nil else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.75))
            guard !Task.isCancelled, let self else { return }
            await self.save()
        }
    }

    func isManaged(_ key: UsersPreferenceKey) -> Bool {
        managedKeys.contains(key.rawValue)
    }

    // MARK: - Load

    func load() {
        isLoading = true
        defer { isLoading = false }

        managedKeys = Set(UsersPreferenceKey.allCases.map(\.rawValue).filter(source.isManaged))
        let snapshot = Self.read(from: source)
        apply(snapshot)
        saved = snapshot
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
        additionalExclusionsText = snapshot.additionalExclusions.joined(separator: ", ")
        deleteAdmins = snapshot.deleteAdmins
        deletableAdminsText = snapshot.deletableAdmins.joined(separator: ", ")
    }

    private var current: PreferenceSnapshot {
        PreferenceSnapshot(
            deletionDays: max(0, deletionDays),
            strategy: strategy,
            additionalExclusions: Self.parseNames(additionalExclusionsText),
            deleteAdmins: deleteAdmins,
            deletableAdmins: Self.parseNames(deletableAdminsText)
        )
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

    func save() async {
        guard let client = xpcClient else { return }
        let target = current
        let pending = Self.writes(from: saved, to: target, managed: managedKeys)
        guard !pending.isEmpty else { return }

        saveStatus = .saving
        var failed: [String] = []
        for write in pending {
            let ok: Bool
            let key: UsersPreferenceKey
            switch write {
            case .bool(let k, let value): key = k; ok = await client.setBoolPreference(key: k, value: value)
            case .int(let k, let value): key = k; ok = await client.setIntPreference(key: k, value: value)
            case .string(let k, let value): key = k; ok = await client.setStringPreference(key: k, value: value)
            case .array(let k, let value): key = k; ok = await client.setArrayPreference(key: k, value: value)
            case .remove(let k): key = k; ok = await client.removePreference(key: k)
            }
            if !ok { failed.append(key.rawValue) }
        }

        if failed.isEmpty {
            saved = target
            saveStatus = .saved
            try? await Task.sleep(for: .seconds(2.5))
            if saveStatus == .saved { saveStatus = .idle }
        } else {
            saveStatus = .failed("Could not save \(failed.joined(separator: ", ")): the helper is not available")
        }
    }
}
