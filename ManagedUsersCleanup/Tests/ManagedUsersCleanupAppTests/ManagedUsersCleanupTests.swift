import Foundation
import Testing
@testable import ManagedUsersCleanupApp
import ManagedUsersCleanupXPC

// MARK: - Line levels, against the lines manageusers actually writes

@Suite struct LineLevelTests {
    @Test func logFileLevels() {
        #expect(LineLevel.classify("[2026-10-06 09:14:02] ERROR Deletion of 's1' did not complete: home folder /Users/s1") == .error)
        #expect(LineLevel.classify("[2026-10-06 09:14:02] WARN  sysadminctl could not delete 's1' (exit 1)") == .warning)
        #expect(LineLevel.classify("[2026-10-06 09:14:02] DEBUG User state repair is not implemented in this version; skipped.") == .debug)
        #expect(LineLevel.classify("[2026-10-06 09:14:02] INFO  Keep 's2': excluded.") == .info)
        #expect(LineLevel.classify("[2026-10-06 09:14:02] INFO  ===== ManageUsers started =====") == .header)
    }

    @Test func consoleLevels() {
        #expect(LineLevel.classify("ERROR: Refusing to run manageusers: /usr/local/manageusers/manageusers does not exist") == .error)
        #expect(LineLevel.classify("WARN: Run stopped by user.") == .warning)
        #expect(LineLevel.classify("INFO: 2 accounts would be deleted.") == .info)
    }
}

// MARK: - Log days

@Suite struct LogSessionStoreTests {
    @Test func dayParsing() {
        #expect(LogSessionStore.parseDay("2026-10-06") != nil)
        #expect(LogSessionStore.parseDay("091402") == nil)
    }

    @Test func listsDaysAndLegacyFilesNewestFirst() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("muc-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }

        func write(_ relative: String, _ text: String = "x") throws {
            let path = (root as NSString).appendingPathComponent(relative)
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try write("2026-10-05/manageusers.log")
        try write("2026-10-05/events.jsonl")
        try write("2026-10-06/manageusers.log", "longer content")
        try write("2026-10-04/events.jsonl")
        try write("notaday/manageusers.log")
        try write("manageusers.log.1")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                             ofItemAtPath: (root as NSString).appendingPathComponent("manageusers.log.1"))

        let sessions = LogSessionStore.sessions(in: root)
        let names = sessions.map(\.name)
        #expect(names == ["2026-10-06", "2026-10-05", "manageusers.log.1"])
        #expect(sessions.first?.size == 14)
        #expect(sessions.first?.path.hasSuffix("2026-10-06/manageusers.log") == true)
    }

    @Test func missingRootListsNothing() {
        #expect(LogSessionStore.sessions(in: "/nonexistent/\(UUID().uuidString)").isEmpty)
    }
}

// MARK: - Run modes and the plan

@Suite struct RunModeTests {
    @Test func simulateIsAPlanRun() {
        #expect(RunMode.arguments(for: .simulate, confirmed: ["ignored"]) == ["delete", "--plan"])
    }

    @Test func liveRunIsLimitedToConfirmedAccounts() {
        #expect(RunMode.arguments(for: .live, confirmed: ["s1", "j.doe"]) == ["delete", "--live", "--only", "s1", "--only", "j.doe"])
    }

    @Test func liveRunNeedsAValidList() {
        #expect(RunMode.arguments(for: .live, confirmed: []) == nil)
        #expect(RunMode.arguments(for: .live, confirmed: ["--force"]) == nil)
        #expect(RunMode.arguments(for: .live, confirmed: ["a b"]) == nil)
        #expect(RunMode.arguments(for: .live, confirmed: ["../etc"]) == nil)
        #expect(RunMode.arguments(for: .live, confirmed: ["s1", "$(id)"]) == nil)
    }

    @Test func unknownModesAreRejected() {
        #expect(RunMode(rawValue: "delete-all") == nil)
        #expect(RunMode(rawValue: "--live") == nil)
    }

    @Test func helperAcceptsOnlyWindowKeys() {
        #expect(UsersPreferenceKey.isWritable("DeletionDays"))
        #expect(UsersPreferenceKey.isWritable("DeletableAdmins"))
        #expect(!UsersPreferenceKey.isWritable("Exclusions"))
        #expect(!UsersPreferenceKey.isWritable("SecureTokenAdmin"))
        #expect(UsersPreferenceKey.isWritable("DeletionDays", isForced: { _ in false }))
        #expect(!UsersPreferenceKey.isWritable("DeletionDays", isForced: { $0 == "DeletionDays" }))
        #expect(!UsersPreferenceKey.isWritable("Exclusions", isForced: { _ in false }))
    }

    @Test func parsesThePlanLine() {
        let line = #"MANAGEUSERS_PLAN {"accounts":[{"name":"s1","reason":"created 40d ago"},{"name":"s2","reason":"last login never"}]}"#
        #expect(PlannedDeletion.parsePlanLine(line) == [
            PlannedDeletion(name: "s1", reason: "created 40d ago"),
            PlannedDeletion(name: "s2", reason: "last login never")
        ])
        #expect(PlannedDeletion.parsePlanLine(#"MANAGEUSERS_PLAN {"accounts":[]}"#) == [])
        #expect(PlannedDeletion.parsePlanLine("[2026-10-06 09:14:02] INFO  MANAGEUSERS_PLAN") == nil)
        #expect(PlannedDeletion.parsePlanLine("MANAGEUSERS_PLAN not json") == nil)
    }
}

// MARK: - Preferences

private struct FakeSource: PreferenceSource {
    var values: [String: Any] = [:]
    var managed: Set<String> = []
    func value(forKey key: String) -> Any? { values[key] }
    func isManaged(_ key: String) -> Bool { managed.contains(key) }
}

@Suite @MainActor struct PreferenceTests {
    @Test func readsWithTheToolsMeaning() {
        let snapshot = SettingsViewModel.read(from: FakeSource(values: [
            "DeletionDays": 45,
            "DeletionStrategy": "Creation-Only",
            "AdditionalExclusions": ["kiosk"],
            "DeleteAdmins": 1,
            "DeletableAdmins": "oldadmin, other"
        ]))
        #expect(snapshot.deletionDays == 45)
        #expect(snapshot.strategy == .creationOnly)
        #expect(snapshot.additionalExclusions == ["kiosk"])
        #expect(snapshot.deleteAdmins)
        #expect(snapshot.deletableAdmins == ["oldadmin", "other"])
    }

    @Test func defaultsWhenUnsetOrInvalid() {
        #expect(SettingsViewModel.read(from: FakeSource()) == PreferenceSnapshot())
        let odd = SettingsViewModel.read(from: FakeSource(values: ["DeletionDays": -3, "DeletionStrategy": "sometimes"]))
        #expect(odd.deletionDays == 0)
        #expect(odd.strategy == .areaDefault)
    }

    @Test func loadMarksManagedKeys() {
        let model = SettingsViewModel(source: FakeSource(
            values: ["DeletionDays": 30, "DeleteAdmins": true],
            managed: ["DeletionDays", "DeleteAdmins"]
        ))
        model.load()
        #expect(model.isManaged(.deletionDays))
        #expect(model.isManaged(.deleteAdmins))
        #expect(!model.isManaged(.additionalExclusions))
        #expect(model.deletionDays == 30)
        #expect(model.deleteAdmins)
    }

    @Test func writesSkipManagedKeysAndRemoveDefaults() {
        var old = PreferenceSnapshot()
        old.deletionDays = 30
        old.deleteAdmins = true
        old.deletableAdmins = ["x"]
        var new = PreferenceSnapshot()
        new.deletionDays = 0
        new.strategy = .creationOnly
        new.additionalExclusions = ["kiosk", "support"]
        new.deleteAdmins = false

        let writes = SettingsViewModel.writes(from: old, to: new, managed: ["DeletableAdmins"])
        #expect(writes == [
            .remove(.deletionDays),
            .string(.deletionStrategy, "creation-only"),
            .array(.additionalExclusions, ["kiosk", "support"]),
            .remove(.deleteAdmins)
        ])
        #expect(SettingsViewModel.writes(from: new, to: new, managed: []).isEmpty)
    }

    @Test func parsesNames() {
        #expect(SettingsViewModel.parseNames(" admin, support\nAdmin  guest,,") == ["admin", "support", "guest"])
        #expect(SettingsViewModel.parseNames("").isEmpty)
    }
}

// MARK: - The tool path the helper trusts

@Suite struct PathTrustTests {
    @Test func toolLivesInItsOwnFolder() {
        #expect(CleanupConstants.toolExecutablePath == "/usr/local/manageusers/manageusers")
        #expect(PathTrust.checkedPaths(CleanupConstants.toolExecutablePath)
                == ["/usr/local/manageusers/manageusers", "/usr/local/manageusers", "/usr/local", "/usr", "/"])
    }

    @Test func rootOwnedSystemBinaryIsTrusted() {
        #expect(PathTrust.untrustedPathProblem("/bin/ls") == nil)
    }

    @Test func userOwnedOrLinkedPathsAreRefused() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("muc-trust-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        let tool = (dir as NSString).appendingPathComponent("manageusers")
        try Data().write(to: URL(fileURLWithPath: tool))
        #expect(PathTrust.untrustedPathProblem(tool)?.contains("not owned by root") == true)

        let link = (dir as NSString).appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: "/bin/ls")
        #expect(PathTrust.untrustedPathProblem(link)?.contains("symbolic link") == true)

        #expect(PathTrust.untrustedPathProblem(dir + "/missing")?.contains("does not exist") == true)
    }
}


@Suite("Managed preferences file check")
struct ManagedPreferencesFileTests {
    @Test("Finds a key set in a managed preferences plist, and only that key")
    func readsManagedFile() throws {
        let path = NSTemporaryDirectory() + "managed-\(UUID().uuidString).plist"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try (["DeletionDays": 45] as NSDictionary).write(to: URL(fileURLWithPath: path))
        #expect(UsersPreferenceKey.managedFileSetsKey("DeletionDays", path: path))
        #expect(!UsersPreferenceKey.managedFileSetsKey("DeleteAdmins", path: path))
        #expect(!UsersPreferenceKey.managedFileSetsKey("DeletionDays", path: path + ".missing"))
    }
}
