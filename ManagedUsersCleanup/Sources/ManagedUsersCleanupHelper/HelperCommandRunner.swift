//
//  HelperCommandRunner.swift
//  ManagedUsersCleanupHelper
//
//  Implements the XPC protocol: runs manageusers in a fixed mode with output
//  streaming, and writes its system-level preferences.
//

import Foundation
import ManagedUsersCleanupXPC

final class HelperCommandRunner: NSObject, HelperXPCProtocol, @unchecked Sendable {
    // Safety invariant: `process` is only mutated on the XPC dispatch queue
    // which serializes all incoming calls. The connection holds a strong
    // reference to this object; invalidationHandler calls cancelRunningProcess
    // on the same queue.
    private let connection: NSXPCConnection
    private var process: Process?

    private static var domain: CFString { CleanupConstants.preferenceDomain as CFString }

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    // MARK: - Runs

    func run(mode: String, accounts: [String]) {
        let clientProxy = connection.remoteObjectProxy as? HelperXPCClientProtocol

        guard let runMode = RunMode(rawValue: mode),
              let arguments = RunMode.arguments(for: runMode, confirmed: accounts) else {
            clientProxy?.didEncounterError(mode == RunMode.live.rawValue
                ? "A live cleanup needs a confirmed list of valid account names."
                : "Unknown run mode: \(mode)")
            clientProxy?.runDidComplete(success: false, exitCode: -1)
            return
        }
        guard process == nil else {
            clientProxy?.didEncounterError("A run is already in progress.")
            return
        }
        let executable = CleanupConstants.toolExecutablePath
        if let problem = PathTrust.untrustedPathProblem(executable) {
            clientProxy?.didEncounterError("Refusing to run manageusers: \(problem)")
            clientProxy?.runDidComplete(success: false, exitCode: -1)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        // A fixed, minimal environment: nothing from the helper's own environment
        // reaches the tool. NSUnbufferedIO makes lines stream instead of arriving
        // when the run ends.
        task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "NSUnbufferedIO": "YES"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        process = task

        // Stream output line by line on a background queue
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    clientProxy?.didReceiveOutput(line)
                }
            }
        }

        task.terminationHandler = { [weak self] proc in
            handle.readabilityHandler = nil
            let remaining = handle.readDataToEndOfFile()
            if !remaining.isEmpty, let text = String(data: remaining, encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    clientProxy?.didReceiveOutput(line)
                }
            }
            let exitCode = proc.terminationStatus
            clientProxy?.runDidComplete(success: exitCode == 0, exitCode: exitCode)
            self?.process = nil
        }

        do {
            try task.run()
        } catch {
            clientProxy?.didEncounterError("Failed to launch manageusers: \(error.localizedDescription)")
            clientProxy?.runDidComplete(success: false, exitCode: -1)
            process = nil
        }
    }

    func stop() {
        cancelRunningProcess()
    }

    func cancelRunningProcess() {
        process?.terminate()
        process = nil
    }

    // MARK: - Preferences
    //
    // Writes land in /Library/Preferences/com.github.manageusers.plist
    // (any user, any host), the file the root tool reads below a profile. The
    // domain is fixed and only the keys the window edits are accepted.

    func setBoolPreference(key: String, value: Bool, withReply reply: @escaping (Bool) -> Void) {
        write(key: key, value: value as CFBoolean, reply: reply)
    }

    func setIntPreference(key: String, value: Int, withReply reply: @escaping (Bool) -> Void) {
        write(key: key, value: value as CFNumber, reply: reply)
    }

    func setStringPreference(key: String, value: String, withReply reply: @escaping (Bool) -> Void) {
        guard key != UsersPreferenceKey.deletionStrategy.rawValue
                || ["login-and-creation", "creation-only"].contains(value) else {
            reply(false)
            return
        }
        write(key: key, value: value as CFString, reply: reply)
    }

    func setArrayPreference(key: String, value: [String], withReply reply: @escaping (Bool) -> Void) {
        write(key: key, value: value as CFArray, reply: reply)
    }

    func removePreference(key: String, withReply reply: @escaping (Bool) -> Void) {
        write(key: key, value: nil, reply: reply)
    }

    private func write(key: String, value: CFPropertyList?, reply: @escaping (Bool) -> Void) {
        let domain = Self.domain
        guard UsersPreferenceKey.isWritable(key, isForced: { CFPreferencesAppValueIsForced($0 as CFString, domain) }) else {
            NSLog("Managed Users Cleanup helper refused a write to %@", key)
            reply(false)
            return
        }
        CFPreferencesSetValue(key as CFString, value, Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        reply(CFPreferencesSynchronize(Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost))
    }

    // MARK: - Version

    func getHelperVersion(withReply reply: @escaping (String) -> Void) {
        reply(Self.bundleVersion)
    }

    /// The version of the app bundle the helper ships in.
    static let bundleVersion: String = {
        let ownPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let infoPlist = ownPath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoPlist) else { return "unknown" }
        let short = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short).\(build)"
    }()
}
