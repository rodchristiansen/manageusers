import Foundation
import Logging

class RemediationManager {
    private let verbose: Bool
    private let logger: Logging.Logger
    private let log = ManagementLog.shared
    
    private let customExcludeUsers = [
        "admin", "student", "doc", "cts", "fvim", "fmsa", "nmsatech"
    ]
    
    private let alwaysExcludedUsers = [
        "_mbsetupuser", "root", "daemon", "nobody", "sys", "guest",
        ".localized", "loginwindow", "Shared", "Library"
    ]
    
    init(verbose: Bool) {
        self.verbose = verbose
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        self.logger = Logging.Logger(label: "RemediationManager")
    }
    
    // MARK: - SecureToken Management
    func checkSecureToken(for username: String? = nil) async throws {
        print("Checking SecureToken status...")
        
        if let specificUser = username {
            try await checkSecureTokenForUser(specificUser)
        } else {
            let users = try await getAllUsers()
            for user in users {
                if !user.hasPrefix("_") {
                    try await checkSecureTokenForUser(user)
                }
            }
        }
    }
    
    private func checkSecureTokenForUser(_ username: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
        process.arguments = ["-secureTokenStatus", username]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        print("Checking SecureToken status for user: \(username)")
        if output.contains("ENABLED") {
            print("  ✓ SecureToken: ENABLED")
        } else if output.contains("DISABLED") {
            print("  ✗ SecureToken: DISABLED")
        } else {
            print("  ? SecureToken: UNKNOWN (\(output.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }
    }
    
    // MARK: - User Cleanup
    /// Orphans go through the same evaluator as the main run: exclusions and
    /// admin protection apply, and an account must be older than `days`.
    /// Nothing is changed unless `simulate` is false (`--live`).
    func cleanupOrphans(type: String, simulate: Bool, days: Int) async throws {
        log.info("Starting orphan cleanup (type: \(type), simulate: \(simulate), older than \(days)d)...")

        switch type.lowercased() {
        case "dscl-orphans":
            try await cleanupDsclOrphans(simulate: simulate, days: days)
        case "home-orphans":
            try await cleanupHomeOrphans(simulate: simulate, days: days)
        case "both":
            try await cleanupDsclOrphans(simulate: simulate, days: days)
            try await cleanupHomeOrphans(simulate: simulate, days: days)
        default:
            throw RemediationError.invalidCleanupType(type)
        }

        log.info("Orphan cleanup completed.")
    }

    /// The same exclusions the main run uses: the built-in names plus the
    /// Exclusions array in the sessions plist, so a remediation command never
    /// deletes someone the scheduled run would keep.
    private func protection() -> AccountProtection {
        let settings = AdminGuardSettings.load()
        var sessionExclusions: [String] = []
        if let data = FileManager.default.contents(atPath: "/Library/Management/Cache/UserSessions.plist"),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let names = plist["Exclusions"] as? [String] {
            sessionExclusions = names
        }
        return AccountProtection(
            exclusions: alwaysExcludedUsers + customExcludeUsers + UserManagementConstants.alwaysExcludedUsers + sessionExclusions,
            deleteAdmins: settings.deleteAdmins,
            deletableAdmins: settings.deletableAdmins
        )
    }

    private func cleanupDsclOrphans(simulate: Bool, days: Int) async throws {
        log.info("Checking accounts that have no home folder...")
        let inspector = AccountInspector()
        let volumeUsers = inspector.volumeUsers()
        let owners = inspector.adminVolumeOwners(volumeUsers: volumeUsers)
        let policy = DeletionPolicy(duration: days * 86_400, strategy: .loginAndCreation, forceTermDeletion: false)
        let guardSet = protection()
        var count = 0

        for user in inspector.localUserNames().sorted() where !FileManager.default.fileExists(atPath: "/Users/\(user)") {
            let facts = inspector.facts(for: user, lastLogin: nil, recordedCreation: nil, volumeUsers: volumeUsers)
            let decision = DeletionEvaluator.evaluate(facts, policy: policy, protection: guardSet,
                                                      adminVolumeOwnersRemaining: owners.subtracting([user]).count)
            guard decision.shouldDelete else {
                log.info("Keep orphaned account '\(user)': \(decision.reason)")
                continue
            }
            count += 1
            if simulate {
                log.info("SIMULATION: would delete orphaned account '\(user)' (\(decision.reason))")
                continue
            }
            do {
                try UserDeleter(log: { level, message in ManagementLog.shared.write(level, message) }).delete(user)
                log.info("Deleted orphaned account '\(user)' and verified it is gone")
            } catch {
                log.error("\(error)")
            }
        }
        log.info(count == 0 ? "No orphaned accounts to remove." : "\(count) orphaned account(s) \(simulate ? "would be" : "were") processed.")
    }

    /// Home folders with no account. Removed only when the folder is a real
    /// directory (never a link), is not excluded, and was created more than
    /// `days` ago.
    private func cleanupHomeOrphans(simulate: Bool, days: Int) async throws {
        log.info("Checking home folders that have no account...")
        let inspector = AccountInspector()
        let guardSet = protection()
        let cutoff = Date().addingTimeInterval(-TimeInterval(days * 86_400))
        var count = 0

        for dir in try FileManager.default.contentsOfDirectory(atPath: "/Users").sorted() {
            let path = "/Users/\(dir)"
            guard !dir.hasPrefix("."), !guardSet.isExcluded(dir), !inspector.exists(dir),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            let created = attributes[.creationDate] as? Date ?? Date()
            guard created < cutoff else {
                log.info("Keep home folder \(path): created within \(days)d")
                continue
            }
            count += 1
            if simulate {
                log.info("SIMULATION: would remove home folder \(path)")
            } else {
                try await removeDirectory(path)
                log.info("Removed home folder \(path)")
            }
        }
        log.info(count == 0 ? "No orphaned home folders to remove." : "\(count) orphaned home folder(s) \(simulate ? "would be" : "were") processed.")
    }
    
    // MARK: - User Counting and Listing
    func countUsers(listUsers: Bool) async throws {
        let guiUsers = try getGUIUsers()
        let dsclUsers = try await getDsclUsers()
        
        print("Number of Graphical Users (GUI): \(guiUsers.count)")
        print("Number of dscl Users: \(dsclUsers.count)")
        print("--------------------------------------")
        
        if listUsers {
            print("GUI USERS (Filtered):")
            for user in guiUsers.sorted() {
                print("  \(user)")
            }
            print("--------------------------------------")
            
            print("DSCL USERS (Filtered):")
            for user in dsclUsers.sorted() {
                print("  \(user)")
            }
        }
    }
    
    func listUsers(filter: String, includeDetails: Bool) async throws {
        print("Listing users with filter: \(filter)")
        print("======================================")
        
        switch filter.lowercased() {
        case "all":
            try await listAllUsers(includeDetails: includeDetails)
        case "gui":
            try await listGUIUsers(includeDetails: includeDetails)
        case "dscl":
            try await listDsclUsers(includeDetails: includeDetails)
        case "excluded":
            try await listExcludedUsers()
        default:
            throw RemediationError.invalidFilterType(filter)
        }
    }
    
    private func listAllUsers(includeDetails: Bool) async throws {
        let guiUsers = try getGUIUsers()
        let dsclUsers = try await getDsclUsers()
        let allUsers = Set(guiUsers).union(Set(dsclUsers)).sorted()
        
        print("All Users (\(allUsers.count)):")
        for user in allUsers {
            let hasGUI = guiUsers.contains(user)
            let hasDscl = dsclUsers.contains(user)
            let status = hasGUI && hasDscl ? "GUI+DSCL" : hasGUI ? "GUI only" : "DSCL only"
            
            print("  \(user) (\(status))")
            
            if includeDetails {
                try await printUserDetails(user)
            }
        }
    }
    
    private func listGUIUsers(includeDetails: Bool) async throws {
        let users = try getGUIUsers()
        print("GUI Users (\(users.count)):")
        for user in users.sorted() {
            print("  \(user)")
            if includeDetails {
                try await printUserDetails(user)
            }
        }
    }
    
    private func listDsclUsers(includeDetails: Bool) async throws {
        let users = try await getDsclUsers()
        print("DSCL Users (\(users.count)):")
        for user in users.sorted() {
            print("  \(user)")
            if includeDetails {
                try await printUserDetails(user)
            }
        }
    }
    
    private func listExcludedUsers() async throws {
        let allExcluded = (alwaysExcludedUsers + customExcludeUsers).sorted()
        print("Excluded Users (\(allExcluded.count)):")
        for user in allExcluded {
            print("  \(user)")
        }
    }
    
    private func printUserDetails(_ username: String) async throws {
        // Get UID
        if let uid = try await getUID(for: username) {
            print("    UID: \(uid)")
        }
        
        // Check if home directory exists
        let homeExists = FileManager.default.fileExists(atPath: "/Users/\(username)")
        print("    Home Directory: \(homeExists ? "✓ Exists" : "✗ Missing")")
        
        // Check SecureToken status
        let secureTokenStatus = try await getSecureTokenStatus(for: username)
        print("    SecureToken: \(secureTokenStatus)")
    }
    
    // MARK: - Delete All Users
    /// Deletes every account the evaluator allows with a zero-day threshold.
    /// Exclusions, admin protection and the last volume owner are still kept.
    /// Runs as root; no password is taken or passed to any tool.
    func deleteAllUsers(simulate: Bool, force: Bool) async throws {
        let inspector = AccountInspector()
        let volumeUsers = inspector.volumeUsers()
        let owners = inspector.adminVolumeOwners(volumeUsers: volumeUsers)
        let policy = DeletionPolicy(duration: 0, strategy: .loginAndCreation, forceTermDeletion: true)
        let guardSet = protection()

        var usersToDelete: [String] = []
        for user in inspector.localUserNames().sorted() {
            let facts = inspector.facts(for: user, lastLogin: nil, recordedCreation: nil, volumeUsers: volumeUsers)
            let decision = DeletionEvaluator.evaluate(facts, policy: policy, protection: guardSet,
                                                      adminVolumeOwnersRemaining: owners.subtracting([user]).count)
            if decision.shouldDelete {
                usersToDelete.append(user)
            } else {
                print("Keeping \(user): \(decision.reason)")
            }
        }

        if usersToDelete.isEmpty {
            print("No deletable users found.")
            return
        }

        print("Users to delete: \(usersToDelete)")

        if simulate {
            for user in usersToDelete { log.info("SIMULATION: would delete user: \(user)") }
            print("Simulation only. Pass --live to delete.")
            return
        }

        if !force {
            print("\nWARNING: This will DELETE the users listed above. This cannot be undone.")
            print("Type 'DELETE ALL USERS' to continue: ", terminator: "")
            guard readLine() == "DELETE ALL USERS" else {
                print("Operation cancelled.")
                return
            }
        }

        let deleter = UserDeleter(log: { level, message in ManagementLog.shared.write(level, message) })
        for user in usersToDelete {
            log.info("Deleting user: \(user)")
            do {
                try deleter.delete(user)
                log.info("Deleted '\(user)' and verified it is gone")
            } catch {
                log.error("\(error)")
            }
        }

        log.info("Delete all users operation completed.")
    }
    
    // MARK: - XCreds Management
    func manageXCreds(action: String) async throws {
        log.info("Managing XCreds with action: \(action)")
        
        switch action.lowercased() {
        case "load":
            try await loadXCreds()
        case "unload":  
            try await unloadXCreds()
        case "uninstall":
            try await uninstallXCreds()
        case "status":
            try await getXCredsStatus()
        default:
            throw RemediationError.invalidXCredsAction(action)
        }
    }
    
    private func loadXCreds() async throws {
        log.info("Loading XCreds launch agents...")
        let launchAgentPaths = [
            "/Library/LaunchAgents/com.twocanoes.xcreds.plist"
        ]
        
        for path in launchAgentPaths {
            if FileManager.default.fileExists(atPath: path) {
                try await runCommand(["/bin/launchctl", "load", path])
                log.info("Loaded: \(path)")
            }
        }
    }
    
    private func unloadXCreds() async throws {
        log.info("Unloading XCreds launch agents...")
        let launchAgentPaths = [
            "/Library/LaunchAgents/com.twocanoes.xcreds.plist"
        ]
        
        for path in launchAgentPaths {
            if FileManager.default.fileExists(atPath: path) {
                try await runCommand(["/bin/launchctl", "unload", path])
                log.info("Unloaded: \(path)")
            }
        }
    }
    
    private func uninstallXCreds() async throws {
        log.info("Uninstalling XCreds...")
        
        // Unload first
        try await unloadXCreds()
        
        // Remove files
        let pathsToRemove = [
            "/Library/LaunchAgents/com.twocanoes.xcreds.plist",
            "/Applications/XCreds.app"
        ]
        
        for path in pathsToRemove {
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
                log.info("Removed: \(path)")
            }
        }
        
        log.info("XCreds uninstalled.")
    }
    
    private func getXCredsStatus() async throws {
        print("XCreds Status:")
        
        let xCredsApp = "/Applications/XCreds.app"
        let launchAgent = "/Library/LaunchAgents/com.twocanoes.xcreds.plist"
        
        print("  Application: \(FileManager.default.fileExists(atPath: xCredsApp) ? "✓ Installed" : "✗ Not found")")
        print("  Launch Agent: \(FileManager.default.fileExists(atPath: launchAgent) ? "✓ Present" : "✗ Not found")")
        
        // Check if loaded
        if FileManager.default.fileExists(atPath: launchAgent) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["list", "com.twocanoes.xcreds"]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                print("  Status: ✓ Loaded and running")
            } else {
                print("  Status: ✗ Not loaded")
            }
        }
    }
    
    // MARK: - Directory Cache Management
    func flushDirectoryCache() async throws {
        log.info("Flushing directory services cache...")
        
        let commands = [
            ["/usr/bin/dscacheutil", "-flushcache"],
            ["/usr/bin/killall", "-HUP", "opendirectoryd"]
        ]
        
        for command in commands {
            try await runCommand(command)
        }
        
        // Remove cache directory
        let cacheDir = "/var/db/dslocal/nodes/Default/cache"
        if FileManager.default.fileExists(atPath: cacheDir) {
            try FileManager.default.removeItem(atPath: cacheDir)
            log.info("Removed cache directory: \(cacheDir)")
        }
        
        log.info("Directory services cache flushed successfully.")
    }
    
    // MARK: - Helper Methods
    private func getAllUsers() async throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = [".", "list", "/Users"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    private func getDsclUsers() async throws -> [String] {
        let allUsers = try await getAllUsers()
        return allUsers.filter { !$0.hasPrefix("_") && $0 != "nobody" && $0 != "daemon" }
    }
    
    private func getGUIUsers() throws -> [String] {
        let userDirectories = try FileManager.default.contentsOfDirectory(atPath: "/Users")
        return userDirectories.filter { dirname in
            !["Library", "Shared", ".localized", "loginwindow"].contains(dirname)
        }
    }
    
    private func getUID(for username: String) async throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/id")
        process.arguments = ["-u", username]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return nil
    }
    
    private func getSecureTokenStatus(for username: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
        process.arguments = ["-secureTokenStatus", username]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        if output.contains("ENABLED") {
            return "ENABLED"
        } else if output.contains("DISABLED") {
            return "DISABLED"
        } else {
            return "UNKNOWN"
        }
    }
    
    private func removeDirectory(_ path: String) async throws {
        // Set permissions to allow removal
        let chmodProcess = Process()
        chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodProcess.arguments = ["-R", "u+w", path]
        try chmodProcess.run()
        chmodProcess.waitUntilExit()
        
        // Clear immutable flags
        let chflagsProcess = Process()
        chflagsProcess.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        chflagsProcess.arguments = ["-R", "nouchg", path]
        try chflagsProcess.run()
        chflagsProcess.waitUntilExit()
        
        // Remove directory
        try FileManager.default.removeItem(atPath: path)
    }
    
    private func runCommand(_ command: [String]) async throws {
        guard !command.isEmpty else { return }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        if command.count > 1 {
            process.arguments = Array(command[1...])
        }
        
        if verbose {
            log.debug("Running: \(command.joined(separator: " "))")
        }
        
        try process.run()
        process.waitUntilExit()
        
        if verbose && process.terminationStatus != 0 {
            log.warning("Command failed with exit code: \(process.terminationStatus)")
        }
    }
}

// MARK: - Remediation Errors
enum RemediationError: Error, LocalizedError {
    case invalidCleanupType(String)
    case invalidFilterType(String)
    case invalidXCredsAction(String)
    case userDeletionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidCleanupType(let type):
            return "Invalid cleanup type: \(type). Valid options: dscl-orphans, home-orphans, both"
        case .invalidFilterType(let filter):
            return "Invalid filter type: \(filter). Valid options: all, gui, dscl, excluded"
        case .invalidXCredsAction(let action):
            return "Invalid XCreds action: \(action). Valid options: load, unload, uninstall, status"
        case .userDeletionFailed(let username):
            return "Failed to delete user: \(username)"
        }
    }
}