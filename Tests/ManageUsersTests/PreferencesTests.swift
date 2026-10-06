import Testing
import Foundation
@testable import manageusers

@Suite("ManageUsersPreferences")
struct PreferencesTests {

    private func prefs(_ values: [String: Any]) -> ManageUsersPreferences {
        ManageUsersPreferences { values[$0] }
    }

    @Test("A run flag beats the configured threshold")
    func flagBeatsSetting() {
        #expect(prefs(["DeletionDays": 30]).deletionDays(flag: 7) == 7)
    }

    @Test("The configured threshold applies when no flag is given")
    func settingApplies() {
        #expect(prefs(["DeletionDays": 30]).deletionDays(flag: nil) == 30)
        #expect(prefs(["DeletionDays": "14"]).deletionDays(flag: nil) == 14)
    }

    @Test("No threshold when nothing valid is set, so the built-in policy stands")
    func defaultsStand() {
        #expect(prefs([:]).deletionDays(flag: nil) == nil)
        #expect(prefs(["DeletionDays": 0]).deletionDays(flag: nil) == nil)
        #expect(prefs(["DeletionDays": -3]).deletionDays(flag: 0) == nil)
    }

    @Test("Strategy: flag, then setting, unknown names ignored")
    func strategy() {
        let p = prefs(["DeletionStrategy": "creation-only"])
        #expect(p.deletionStrategy(flag: nil) == .creationOnly)
        #expect(p.deletionStrategy(flag: "login-and-creation") == .loginAndCreation)
        #expect(p.deletionStrategy(flag: "bogus") == .creationOnly)
        #expect(prefs(["DeletionStrategy": "bogus"]).deletionStrategy(flag: nil) == nil)
    }

    @Test("Additional exclusions are trimmed and blanks dropped")
    func exclusions() {
        #expect(prefs(["AdditionalExclusions": [" lab ", "", "kiosk"]]).additionalExclusions() == ["lab", "kiosk"])
        #expect(prefs([:]).additionalExclusions().isEmpty)
    }
}

@Suite("FileTrust")
struct FileTrustTests {

    private func temporaryDirectory() -> String {
        let path = NSTemporaryDirectory() + "manageusers-trust-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        return path
    }

    @Test("A file only its owner can write, in such a folder, is trusted")
    func trustedFile() throws {
        let dir = temporaryDirectory()
        let file = dir + "/UserSessions.plist"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        chmod(file, 0o644)
        #expect(FileTrust.isTrustedFile(file))
    }

    @Test("A file others can write is not trusted")
    func worldWritableFile() throws {
        let dir = temporaryDirectory()
        let file = dir + "/UserSessions.plist"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        chmod(file, 0o666)
        #expect(!FileTrust.isTrustedFile(file))
    }

    @Test("A file in a folder others can write is not trusted")
    func worldWritableFolder() throws {
        let dir = temporaryDirectory()
        let file = dir + "/UserSessions.plist"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        chmod(file, 0o644)
        chmod(dir, 0o777)
        #expect(!FileTrust.isTrustedFile(file))
    }

    @Test("A link is never trusted")
    func symlink() throws {
        let dir = temporaryDirectory()
        let target = dir + "/real.plist"
        try Data("x".utf8).write(to: URL(fileURLWithPath: target))
        chmod(target, 0o644)
        let link = dir + "/UserSessions.plist"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(!FileTrust.isTrustedFile(link))
    }
}
