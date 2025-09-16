import Foundation
import OSLog

class RemediationManager {
    private let verbose: Bool
    private let logger: Logger
    
    private let customExcludeUsers = [
        "admin", "student", "doc", "cts", "fvim", "fmsa", "nmsatech"
    ]
    
    private let alwaysExcludedUsers = [
        "_mbsetupuser", "root", "daemon", "nobody", "sys", "guest",
        ".localized", "loginwindow", "Shared", "Library"
    ]
    
    init(verbose: Bool) {
        self.verbose = verbose
        self.logger = Logger(label: "RemediationManager")
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
    func cleanupOrphans(type: String, simulate: Bool) async throws {
        print("Starting orphan cleanup (type: \(type), simulate: \(simulate))...")
        
        switch type.lowercased() {
        case "dscl-orphans":
            try await cleanupDsclOrphans(simulate: simulate)
        case "home-orphans":
            try await cleanupHomeOrphans(simulate: simulate)
        case "both":
            try await cleanupDsclOrphans(simulate: simulate)
            try await cleanupHomeOrphans(simulate: simulate)
        default:
            throw RemediationError.invalidCleanupType(type)
        }
        
        print("Orphan cleanup completed.")
    }
    
    private func cleanupDsclOrphans(simulate: Bool) async throws {
        print("Cleaning up orphaned dscl records (users without home directories)...")
        
        let dsclUsers = try await getDsclUsers()
        var orphanCount = 0
        
        for user in dsclUsers {
            let homeDir = "/Users/\(user)"
            if !FileManager.default.fileExists(atPath: homeDir) {
                let allExcluded = alwaysExcludedUsers + customExcludeUsers
                if !allExcluded.contains(user) {
                    print("  Found orphaned user: \(user) (no home directory)")
                    orphanCount += 1
                    
                    if !simulate {
                        try await deleteUserRecord(user)
                        print("    → Deleted user record for \(user)")
                    } else {
                        print("    → SIMULATION: Would delete user record for \(user)")
                    }
                }
            }
        }
        
        if orphanCount == 0 {
            print("  No orphaned dscl records found.")
        } else {
            print("  Processed \(orphanCount) orphaned dscl records.")
        }
    }
    
    private func cleanupHomeOrphans(simulate: Bool) async throws {
        print("Cleaning up orphaned home directories (directories without dscl records)...")
        
        let homeDirectories = try FileManager.default.contentsOfDirectory(atPath: "/Users")
        let dsclUsers = try await getDsclUsers()
        var orphanCount = 0
        
        for dir in homeDirectories {
            if !dsclUsers.contains(dir) {
                let allExcluded = alwaysExcludedUsers + customExcludeUsers
                if !allExcluded.contains(dir) {
                    print("  Found orphaned home directory: /Users/\(dir)")
                    orphanCount += 1
                    
                    if !simulate {
                        try await removeDirectory("/Users/\(dir)")
                        print("    → Removed directory /Users/\(dir)")
                    } else {
                        print("    → SIMULATION: Would remove directory /Users/\(dir)")
                    }
                }
            }
        }
        
        if orphanCount == 0 {
            print("  No orphaned home directories found.")
        } else {
            print("  Processed \(orphanCount) orphaned home directories.")
        }
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
    func deleteAllUsers(simulate: Bool, force: Bool, password: String?) async throws {
        let allExcluded = alwaysExcludedUsers + customExcludeUsers
        let guiUsers = try getGUIUsers()
        let usersToDelete = guiUsers.filter { !allExcluded.contains($0) }
        
        if usersToDelete.isEmpty {
            print("No non-excluded users found to delete.")
            return
        }
        
        print("Users to delete: \(usersToDelete)")
        print("Excluded users (will be skipped): \(allExcluded)")
        
        if !force && !simulate {
            print("\n⚠️  WARNING: This will DELETE ALL non-excluded users!")
            print("This action cannot be undone.")
            print("Type 'DELETE ALL USERS' to continue: ", terminator: "")
            
            let input = readLine() ?? ""
            if input != "DELETE ALL USERS" {
                print("Operation cancelled.")
                return
            }
        }
        
        let adminPassword: String
        if let providedPassword = password {
            adminPassword = providedPassword
        } else {
            adminPassword = try await getAdminPassword()
        }
        
        for user in usersToDelete {
            if simulate {
                print("SIMULATION: Would delete user: \(user)")
            } else {
                print("Deleting user: \(user)")
                try await deleteUserWithPassword(user, adminPassword: adminPassword)
            }
        }
        
        print("Delete all users operation completed.")
    }
    
    // MARK: - XCreds Management
    func manageXCreds(action: String) async throws {
        print("Managing XCreds with action: \(action)")
        
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
        print("Loading XCreds launch agents...")
        let launchAgentPaths = [
            "/Library/LaunchAgents/com.twocanoes.xcreds.plist"
        ]
        
        for path in launchAgentPaths {
            if FileManager.default.fileExists(atPath: path) {
                try await runCommand(["/bin/launchctl", "load", path])
                print("  Loaded: \(path)")
            }
        }
    }
    
    private func unloadXCreds() async throws {
        print("Unloading XCreds launch agents...")
        let launchAgentPaths = [
            "/Library/LaunchAgents/com.twocanoes.xcreds.plist"
        ]
        
        for path in launchAgentPaths {
            if FileManager.default.fileExists(atPath: path) {
                try await runCommand(["/bin/launchctl", "unload", path])
                print("  Unloaded: \(path)")
            }
        }
    }
    
    private func uninstallXCreds() async throws {
        print("Uninstalling XCreds...")
        
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
                print("  Removed: \(path)")
            }
        }
        
        print("XCreds uninstalled.")
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
        print("Flushing directory services cache...")
        
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
            print("  Removed cache directory: \(cacheDir)")
        }
        
        print("Directory services cache flushed successfully.")
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
    
    private func deleteUserRecord(_ username: String) async throws {
        // Try sysadminctl first
        let process1 = Process()
        process1.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
        process1.arguments = ["-deleteUser", username]
        
        try process1.run()
        process1.waitUntilExit()
        
        // If that fails, try dscl
        if process1.terminationStatus != 0 {
            let process2 = Process()
            process2.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
            process2.arguments = [".", "-delete", "/Users/\(username)"]
            
            try process2.run()
            process2.waitUntilExit()
        }
    }
    
    private func deleteUserWithPassword(_ username: String, adminPassword: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
        process.arguments = ["-deleteUser", username, "-adminUser", "Administrator", "-adminPassword", adminPassword]
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw RemediationError.userDeletionFailed(username)
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
    
    private func getAdminPassword() async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "ManagedInstalls", "SecureTokenAdmin"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw RemediationError.adminPasswordNotFound
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let base64String = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let decodedData = Data(base64Encoded: base64String),
              let password = String(data: decodedData, encoding: .utf8) else {
            throw RemediationError.adminPasswordDecodeError
        }
        
        return password
    }
    
    private func runCommand(_ command: [String]) async throws {
        guard !command.isEmpty else { return }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        if command.count > 1 {
            process.arguments = Array(command[1...])
        }
        
        if verbose {
            print("  Running: \(command.joined(separator: " "))")
        }
        
        try process.run()
        process.waitUntilExit()
        
        if verbose && process.terminationStatus != 0 {
            print("  Command failed with exit code: \(process.terminationStatus)")
        }
    }
}

// MARK: - Remediation Errors
enum RemediationError: Error, LocalizedError {
    case invalidCleanupType(String)
    case invalidFilterType(String)
    case invalidXCredsAction(String)
    case adminPasswordNotFound
    case adminPasswordDecodeError
    case userDeletionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidCleanupType(let type):
            return "Invalid cleanup type: \(type). Valid options: dscl-orphans, home-orphans, both"
        case .invalidFilterType(let filter):
            return "Invalid filter type: \(filter). Valid options: all, gui, dscl, excluded"
        case .invalidXCredsAction(let action):
            return "Invalid XCreds action: \(action). Valid options: load, unload, uninstall, status"
        case .adminPasswordNotFound:
            return "Admin password not found in ManagedInstalls.plist"
        case .adminPasswordDecodeError:
            return "Failed to decode admin password from base64"
        case .userDeletionFailed(let username):
            return "Failed to delete user: \(username)"
        }
    }
}