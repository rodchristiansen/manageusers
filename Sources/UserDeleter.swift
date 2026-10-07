import Foundation

enum UserDeletionError: Error, CustomStringConvertible {
    case notRoot
    case recordStillPresent(String)
    case verificationFailed(String, [String])

    var description: String {
        switch self {
        case .notRoot:
            return "Deleting accounts needs root"
        case .recordStillPresent(let name):
            return "The directory record for '\(name)' is still present; its home folder was left in place"
        case .verificationFailed(let name, let leftovers):
            return "Deletion of '\(name)' did not complete: \(leftovers.joined(separator: ", "))"
        }
    }
}

/// Deletes one local account as root, then checks that it is really gone.
/// It never reports success it did not observe.
struct UserDeleter {
    let inspector = AccountInspector()
    let log: (LogLevel, String) -> Void

    func delete(_ name: String) throws {
        guard geteuid() == 0 else { throw UserDeletionError.notRoot }

        let uid = inspector.attribute(name, "UniqueID")
        let guid = inspector.attribute(name, "GeneratedUID")
        let home = inspector.attribute(name, "NFSHomeDirectory")

        endSessions(name: name, uid: uid)

        let sysadminctl = CommandRunner.run("/usr/sbin/sysadminctl", ["-deleteUser", name, "-secure"])
        if sysadminctl.status != 0 || inspector.exists(name) {
            log(.warning, "sysadminctl could not delete '\(name)' (exit \(sysadminctl.status)); removing the directory record directly")
            CommandRunner.run("/usr/bin/dscl", [".", "-delete", "/Users/\(name)"])
        }

        flushDirectoryCache()
        guard !inspector.exists(name) else {
            throw UserDeletionError.recordStillPresent(name)
        }

        if let guid, volumeHasUser(guid) {
            let result = CommandRunner.run("/usr/sbin/diskutil", ["apfs", "deleteUser", "/", guid])
            if result.status != 0 {
                log(.warning, "diskutil could not remove the volume user for '\(name)': \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        if let path = Self.removableHome(home, for: name) {
            removeHome(path)
        }

        flushDirectoryCache()
        let leftovers = remaining(name: name, guid: guid, home: Self.removableHome(home, for: name))
        guard leftovers.isEmpty else {
            throw UserDeletionError.verificationFailed(name, leftovers)
        }
    }

    /// What is still on disk or in the directory for a deleted account.
    func remaining(name: String, guid: String?, home: String?) -> [String] {
        var leftovers: [String] = []
        if inspector.exists(name) { leftovers.append("directory record") }
        if CommandRunner.run("/usr/bin/id", ["-u", name]).status == 0 { leftovers.append("account still resolves") }
        if let home, FileManager.default.fileExists(atPath: home) { leftovers.append("home folder \(home)") }
        if let guid, volumeHasUser(guid) { leftovers.append("volume user \(guid)") }
        return leftovers
    }

    /// Only a real folder at /Users/<name> is removed: never a link, never a
    /// path outside /Users, never a shared or system folder.
    static func removableHome(_ home: String?, for name: String) -> String? {
        let expected = "/Users/\(name)"
        guard !name.isEmpty, !name.contains("/"), name != "Shared", name != ".." , name != "." else { return nil }
        if let home, home != expected { return nil }
        return expected
    }

    private func endSessions(name: String, uid: String?) {
        if CommandRunner.run("/usr/bin/pgrep", ["-u", name]).status == 0 {
            CommandRunner.run("/usr/bin/pkill", ["-TERM", "-u", name])
            Thread.sleep(forTimeInterval: 2)
            CommandRunner.run("/usr/bin/pkill", ["-KILL", "-u", name])
        }
        if let uid {
            CommandRunner.run("/bin/launchctl", ["bootout", "gui/\(uid)"])
        }
    }

    private func volumeHasUser(_ guid: String) -> Bool {
        inspector.volumeUsers().contains { $0.uuid.uppercased() == guid.uppercased() }
    }

    private func removeHome(_ path: String) {
        var isDirectory: ObjCBool = false
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        CommandRunner.run("/usr/bin/chflags", ["-R", "-P", "nouchg,noschg", path])
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            log(.warning, "Could not remove \(path): \(error.localizedDescription)")
        }
    }

    private func flushDirectoryCache() {
        CommandRunner.run("/usr/bin/dscacheutil", ["-flushcache"])
        CommandRunner.run("/usr/bin/killall", ["-HUP", "opendirectoryd"])
    }
}
