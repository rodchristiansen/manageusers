import Foundation

/// Runs a system tool without a shell and returns its exit status and output.
/// Arguments are passed as an array, so nothing is interpreted by a shell and no
/// secret ever needs to appear on a command line.
struct CommandRunner {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        var output: String { stdout + stderr }
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: "\(error)")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

/// Reads what the evaluator needs about local accounts from the directory
/// service and the boot volume.
struct AccountInspector {

    struct VolumeUser: Equatable {
        let uuid: String
        let isVolumeOwner: Bool
    }

    /// True when the account has a record in the local directory node.
    func exists(_ name: String) -> Bool {
        CommandRunner.run("/usr/bin/dscl", [".", "-read", "/Users/\(name)", "RecordName"]).status == 0
    }

    func attribute(_ name: String, _ key: String) -> String? {
        let result = CommandRunner.run("/usr/bin/dscl", [".", "-read", "/Users/\(name)", key])
        guard result.status == 0 else { return nil }
        return Self.parseSingleAttribute(result.stdout, key: key)
    }

    func isAdmin(_ name: String) -> Bool {
        let result = CommandRunner.run("/usr/bin/dsmemberutil", ["checkmembership", "-U", name, "-G", "admin"])
        return result.stdout.contains("is a member")
    }

    func hasSecureToken(_ name: String) -> Bool {
        CommandRunner.run("/usr/sbin/sysadminctl", ["-secureTokenStatus", name]).output.contains("ENABLED")
    }

    /// Account creation time from the directory's accountPolicyData.
    func creationDate(_ name: String) -> Date? {
        let result = CommandRunner.run("/usr/bin/dscl", [".", "-read", "/Users/\(name)", "accountPolicyData"])
        guard result.status == 0 else { return nil }
        return Self.parseCreationTime(fromAccountPolicyData: result.stdout)
    }

    /// Crypto users on the boot volume, as `diskutil apfs listUsers / -plist` reports them.
    func volumeUsers() -> [VolumeUser] {
        let result = CommandRunner.run("/usr/sbin/diskutil", ["apfs", "listUsers", "/", "-plist"])
        guard result.status == 0 else { return [] }
        return Self.parseVolumeUsers(Data(result.stdout.utf8))
    }

    /// Local accounts with a UID of 501 or more, the range macOS gives people.
    func localUserNames() -> [String] {
        let result = CommandRunner.run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"])
        guard result.status == 0 else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let uid = Int(parts[parts.count - 1]), uid >= 501 else { return nil }
            let name = String(parts[0])
            return name.hasPrefix("_") ? nil : name
        }
    }

    func facts(for name: String, lastLogin: Date?, recordedCreation: Date?, volumeUsers: [VolumeUser]) -> AccountFacts {
        let guid = attribute(name, "GeneratedUID")?.uppercased()
        let volumeUser = volumeUsers.first { $0.uuid.uppercased() == guid }
        return AccountFacts(
            name: name,
            createdAt: creationDate(name) ?? recordedCreation,
            lastLogin: lastLogin,
            isAdmin: isAdmin(name),
            hasSecureToken: hasSecureToken(name),
            isVolumeOwner: volumeUser?.isVolumeOwner ?? false
        )
    }

    /// Admin accounts that own the boot volume, by name.
    func adminVolumeOwners(volumeUsers: [VolumeUser]) -> Set<String> {
        let owners = Set(volumeUsers.filter(\.isVolumeOwner).map { $0.uuid.uppercased() })
        guard !owners.isEmpty else { return [] }
        var names = Set<String>()
        for name in localUserNames() + ["root"] {
            if let guid = attribute(name, "GeneratedUID")?.uppercased(), owners.contains(guid), isAdmin(name) {
                names.insert(name)
            }
        }
        return names
    }

    // MARK: - Parsing (pure, unit-tested)

    /// `dscl . -read /Users/x Key` prints `Key: value`, or `Key:` then the value
    /// on the next line when it is long.
    static func parseSingleAttribute(_ output: String, key: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = key + ":"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func parseCreationTime(fromAccountPolicyData output: String) -> Date? {
        guard let start = output.range(of: "<?xml") ?? output.range(of: "<plist") else { return nil }
        let xml = String(output[start.lowerBound...])
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any],
              let value = plist["creationTime"] else { return nil }
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
        return nil
    }

    static func parseVolumeUsers(_ data: Data) -> [VolumeUser] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let users = plist["Users"] as? [[String: Any]] else { return [] }
        return users.compactMap { entry in
            guard let uuid = entry["APFSCryptoUserUUID"] as? String else { return nil }
            return VolumeUser(uuid: uuid, isVolumeOwner: entry["VolumeOwner"] as? Bool ?? false)
        }
    }
}
