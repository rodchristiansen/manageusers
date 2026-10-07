//
//  HelperXPCProtocol.swift
//  Managed Users Cleanup
//
//  The protocol, constants and run modes shared by the GUI and the privileged
//  helper. The helper runs the installed manageusers binary with the fixed
//  arguments a run mode names; it never takes a command line from the caller.
//

import Foundation

/// Mach service name for the privileged helper.
public let kHelperMachServiceName = "com.github.manageusers.helper"

public enum CleanupConstants {
    /// The manageusers preference domain. The helper writes only this domain.
    public static let preferenceDomain = "com.github.manageusers"
    /// The signing identifier of the GUI. The helper accepts no other client.
    public static let appIdentifier = "com.github.manageusers.gui"
    /// The manageusers command-line tool, in its own folder as its package
    /// installs it. The helper runs this path, never the /usr/local/bin
    /// symlink, so the root-owned check covers /usr/local/manageusers.
    public static let toolExecutablePath = "/usr/local/manageusers/manageusers"
    /// Where manageusers writes its day directories.
    public static let logsDirectory = "/Library/Managed Users/logs"
    /// The prefix of the line `manageusers delete --plan` prints last.
    public static let planPrefix = "MANAGEUSERS_PLAN "
    /// Account names are short POSIX names; anything else is refused before it
    /// reaches the tool.
    public static func isValidAccountName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255, !name.hasPrefix("-"), !name.hasPrefix(".") else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-" || $0 == "@"
        }
    }
}

public enum PathTrust {
    /// Root runs only a binary that root alone can change: the file and every
    /// directory above it must be root-owned and not group- or world-writable,
    /// and none of them a symlink. Returns the reason when that does not hold.
    public static func untrustedPathProblem(_ path: String) -> String? {
        var current = URL(fileURLWithPath: path).standardized.path
        while true {
            var info = stat()
            guard lstat(current, &info) == 0 else {
                return "\(current) does not exist"
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                return "\(current) is a symbolic link"
            }
            if info.st_uid != 0 {
                return "\(current) is not owned by root"
            }
            if info.st_mode & (S_IWGRP | S_IWOTH) != 0 {
                return "\(current) is writable by users other than root"
            }
            if current == "/" { return nil }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { current = "/" }
        }
    }

    /// The paths the check walks, from the file up to /.
    public static func checkedPaths(_ path: String) -> [String] {
        var paths: [String] = []
        var current = URL(fileURLWithPath: path).standardized.path
        while true {
            paths.append(current)
            if current == "/" { return paths }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { current = "/" }
        }
    }
}

/// The runs the window offers. Each maps to fixed tool arguments.
public enum RunMode: String, CaseIterable, Identifiable, Sendable {
    /// Report what a cleanup would delete, then list it.
    case simulate
    /// Delete the accounts the user confirmed from the last simulation.
    case live

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .simulate: "Simulate"
        case .live: "Live cleanup"
        }
    }

    public var summary: String {
        switch self {
        case .simulate:
            "Shows which accounts the cleanup rules would delete. Nothing is changed."
        case .live:
            "Runs a simulation, asks you to confirm the accounts it lists, then deletes only those. Admins and excluded accounts are never deleted."
        }
    }

    /// The tool arguments for a mode. A live run is limited to the confirmed
    /// accounts, each re-checked against the rules by the tool itself.
    public static func arguments(for mode: RunMode, confirmed accounts: [String]) -> [String]? {
        switch mode {
        case .simulate:
            return ["delete", "--plan"]
        case .live:
            guard !accounts.isEmpty, accounts.allSatisfy(CleanupConstants.isValidAccountName) else { return nil }
            return ["delete", "--live"] + accounts.flatMap { ["--only", $0] }
        }
    }
}

/// One account a simulation would delete, with the rule that matched.
public struct PlannedDeletion: Hashable, Sendable, Identifiable {
    public let name: String
    public let reason: String
    public var id: String { name }

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }

    /// Parses the line `manageusers delete --plan` prints last. Nil when the
    /// line is not a plan line.
    public static func parsePlanLine(_ line: String) -> [PlannedDeletion]? {
        guard line.hasPrefix(CleanupConstants.planPrefix) else { return nil }
        let json = Data(line.dropFirst(CleanupConstants.planPrefix.count).utf8)
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let accounts = object["accounts"] as? [[String: Any]] else { return nil }
        return accounts.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return PlannedDeletion(name: name, reason: entry["reason"] as? String ?? "")
        }
    }
}

/// The manageusers preferences the window edits. The helper refuses every other key.
public enum UsersPreferenceKey: String, CaseIterable, Sendable {
    case deletionDays = "DeletionDays"
    case deletionStrategy = "DeletionStrategy"
    case additionalExclusions = "AdditionalExclusions"
    case deleteAdmins = "DeleteAdmins"
    case deletableAdmins = "DeletableAdmins"

    public static func isWritable(_ key: String) -> Bool {
        UsersPreferenceKey(rawValue: key) != nil
    }

    /// True when the helper may write the key: it is one the window edits and no
    /// configuration profile forces it. A profile-set value always wins, so a write
    /// underneath it would only leave a stale value behind.
    public static func isWritable(_ key: String, isForced: (String) -> Bool) -> Bool {
        isWritable(key) && !isForced(key)
    }
}

/// Protocol exposed by the privileged helper daemon. All methods run as root.
/// XPC proxies are thread-safe by design; Sendable conformance is safe.
@objc public protocol HelperXPCProtocol: Sendable {
    /// Run manageusers in the named mode. For `live`, `accounts` is the list the
    /// user confirmed; it is ignored for `simulate`. Output streams back.
    func run(mode: String, accounts: [String])

    /// Stop the run in progress.
    func stop()

    /// Write a preference to /Library/Preferences/com.github.manageusers.plist.
    func setBoolPreference(key: String, value: Bool, withReply reply: @escaping (Bool) -> Void)
    func setIntPreference(key: String, value: Int, withReply reply: @escaping (Bool) -> Void)
    func setStringPreference(key: String, value: String, withReply reply: @escaping (Bool) -> Void)
    func setArrayPreference(key: String, value: [String], withReply reply: @escaping (Bool) -> Void)
    func removePreference(key: String, withReply reply: @escaping (Bool) -> Void)

    /// The helper's version, to confirm it is alive.
    func getHelperVersion(withReply reply: @escaping (String) -> Void)
}

/// Callback protocol from the helper back to the GUI.
@objc public protocol HelperXPCClientProtocol: Sendable {
    /// One line of output from the running process.
    func didReceiveOutput(_ line: String)

    /// The process finished.
    func runDidComplete(success: Bool, exitCode: Int32)

    /// The helper hit an error outside a normal run.
    func didEncounterError(_ message: String)
}

public extension NSXPCInterface {
    /// The helper interface with its string array arguments allowed through
    /// secure coding.
    static func cleanupHelperInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: HelperXPCProtocol.self)
        let classes = NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>
        interface.setClasses(
            classes,
            for: #selector(HelperXPCProtocol.setArrayPreference(key:value:withReply:)),
            argumentIndex: 1,
            ofReply: false
        )
        interface.setClasses(
            classes,
            for: #selector(HelperXPCProtocol.run(mode:accounts:)),
            argumentIndex: 1,
            ofReply: false
        )
        return interface
    }
}
