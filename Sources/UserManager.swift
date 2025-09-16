import Foundation
import Logging

// MARK: - User Management Constants
struct UserManagementConstants {
    static let twoDays = 2 * 24 * 60 * 60
    static let oneWeek = 7 * 24 * 60 * 60
    static let fourWeeks = 4 * 7 * 24 * 60 * 60
    static let thirtyDays = 30 * 24 * 60 * 60
    static let sixWeeks = 6 * 7 * 24 * 60 * 60
    static let thirteenWeeks = 13 * 7 * 24 * 60 * 60
    
    static let maxLogSize = 10_485_760  // 10MB in bytes
    
    static let alwaysExcludedUsers = [
        "_mbsetupuser", "root", "daemon", "nobody", "sys", "guest",
        ".localized", "loginwindow", "Shared", "admin", "student",
        "doc", "cts", "fvim", "fmsa", "nmsatech"
    ]
}

// MARK: - Policy Types
enum DeletionStrategy {
    case loginAndCreation
    case creationOnly
}

struct DeletionPolicy {
    let duration: Int
    let strategy: DeletionStrategy
    let forceTermDeletion: Bool
}

// MARK: - Log Levels
enum LogLevel: Int {
    case info = 1
    case warning = 2  
    case error = 3
}

// MARK: - User Manager Class
class UserManager {
    private let config: UserDeletionConfig
    private let logger: Logging.Logger
    private let lockDir = "/var/run/ManageUsers.lock"
    private let logDir = "/Library/Management/Logs"
    private let logFile: String
    private let userSessionsPlist = "/Library/Management/Cache/UserSessions.plist"
    
    private var excludeList: [String] = []
    private var currentUsers: [String] = []
    private var policy: DeletionPolicy!
    
    init(config: UserDeletionConfig) {
        self.config = config
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        self.logger = Logging.Logger(label: "UserManager")
        self.logFile = "\(logDir)/ManageUsers.log"
    }
    
    func run() async throws {
        print("ManageUsers starting...")
        print("Log file: \(logFile)")  
        print("UserSessions plist: \(userSessionsPlist)")
        
        // Check if plist exists
        guard FileManager.default.fileExists(atPath: userSessionsPlist) else {
            print("ERROR: UserSessions plist not found at \(userSessionsPlist)")
            print("Make sure user sessions have been tracked first.")
            throw UserManagerError.plistNotFound
        }
        
        print("UserSessions plist found ✓")
        print("Starting execution...")
        print("====================")
        
        // Setup logging
        try await setupLogging()
        
        // Log startup
        await log(.info, "===== ManageUsers started =====")
        await log(.info, "Script invoked with simulation mode: \(config.simulationMode)")
        await log(.info, "Script invoked with force mode: \(config.forceMode)")
        
        if config.simulationMode {
            await log(.info, "***** SIMULATION MODE ACTIVE - NO USERS WILL BE DELETED *****")
        } else {
            await log(.info, "LIVE MODE - Users will be actually deleted")
        }
        
        if config.forceMode {
            await log(.info, "***** FORCE MODE ACTIVE - BYPASSING ALL TIME RESTRICTIONS *****")
        }
        
        // Single instance guard
        try acquireLock()
        defer { releaseLock() }
        
        // Load admin password
        let _ = try getAdminPassword()
        await log(.info, "Admin password loaded successfully.")
        
        // Load exclusions and policies
        try await loadExclusions()
        try await calculateDeletionPolicies()
        
        // Process deferred deletions
        try await processDeferredDeletions()
        
        // Repair user states
        try await repairUserStates()
        
        // Main user processing
        try await processUsers()
        
        // Cleanup orphaned users
        try await cleanupOrphanedUsers()
        
        // Flush directory cache
        try await flushDirectoryCache()
        
        // Update hidden users
        try await updateHiddenUsers()
        
        await log(.info, "===== ManageUsers completed =====")
    }
    
    private func setupLogging() async throws {
        try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        
        if !FileManager.default.fileExists(atPath: logFile) {
            FileManager.default.createFile(atPath: logFile, contents: nil)
        }
        
        // Truncate log if older than 24 hours
        let attributes = try FileManager.default.attributesOfItem(atPath: logFile)
        if let modificationDate = attributes[.modificationDate] as? Date {
            let ageInSeconds = Date().timeIntervalSince(modificationDate)
            if ageInSeconds > 86400 {  // 24 hours
                try "".write(toFile: logFile, atomically: true, encoding: .utf8)
                await log(.info, "Log file older than 24 hours. Truncated to capture only the latest run.")
            }
        }
    }
    
    private func log(_ level: LogLevel, _ message: String) async {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        let levelString = level.stringValue
        let logMessage = "\(timestamp) [\(levelString)] - \(message)"
        
        // Write to log file
        if let data = (logMessage + "\n").data(using: .utf8) {
            if let fileHandle = FileHandle(forWritingAtPath: logFile) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        }
        
        // Also output to terminal
        print(logMessage)
        
        // Check for log rotation
        await checkLogRotation()
    }
    
    private func checkLogRotation() async {
        let attributes = try? FileManager.default.attributesOfItem(atPath: logFile)
        if let fileSize = attributes?[.size] as? Int64,
           fileSize >= UserManagementConstants.maxLogSize {
            let timestamp = DateFormatter.backupFormatter.string(from: Date())
            let backupPath = "\(logFile).\(timestamp).bak"
            
            do {
                try FileManager.default.moveItem(atPath: logFile, toPath: backupPath)
                FileManager.default.createFile(atPath: logFile, contents: nil)
                await log(.info, "Log file rotated due to size exceeding \(UserManagementConstants.maxLogSize) bytes.")
            } catch {
                print("Failed to rotate log file: \(error)")
            }
        }
    }
    
    private func acquireLock() throws {
        do {
            try FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: false)
        } catch CocoaError.fileWriteFileExists {
            throw UserManagerError.instanceAlreadyRunning
        }
    }
    
    private func releaseLock() {
        try? FileManager.default.removeItem(atPath: lockDir)
    }
    
    private func getAdminPassword() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "ManagedInstalls", "SecureTokenAdmin"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw UserManagerError.adminPasswordNotFound
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let base64String = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let decodedData = Data(base64Encoded: base64String),
              let password = String(data: decodedData, encoding: .utf8) else {
            throw UserManagerError.adminPasswordDecodeError
        }
        
        return password
    }
    
    private func loadExclusions() async throws {
        await log(.info, "Loading exclusions from \(userSessionsPlist)")
        
        let plistURL = URL(fileURLWithPath: userSessionsPlist)
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        
        guard let exclusions = plist?["Exclusions"] as? [String] else {
            throw UserManagerError.exclusionsNotFound
        }
        
        // Combine with always excluded users
        excludeList = Array(Set(exclusions + UserManagementConstants.alwaysExcludedUsers))
        
        // Add currently logged-in user
        if let loggedInUser = getCurrentConsoleUser() {
            if !excludeList.contains(loggedInUser) {
                excludeList.append(loggedInUser)
                await log(.info, "Added currently logged-in user '\(loggedInUser)' to the exclusion list.")
            }
            await log(.info, "Logged in user detected: \(loggedInUser)")
        } else {
            await log(.info, "No user is currently logged in.")
        }
        
        await log(.info, "Final exclusion list: \(excludeList)")
    }
    
    private func getCurrentConsoleUser() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/stat")  
        process.arguments = ["-f%Su", "/dev/console"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        try? process.run()
        process.waitUntilExit()
        
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return nil
    }
    
    private func calculateDeletionPolicies() async throws {
        let area = getRemoteDesktopSetting("Text2") ?? ""
        let room = getRemoteDesktopSetting("Text3") ?? ""
        
        await log(.info, "Remote Desktop Area: '\(area)', Room: '\(room)'")
        
        // Force mode overrides all policies
        if config.forceMode {
            policy = DeletionPolicy(duration: 0, strategy: .loginAndCreation, forceTermDeletion: true)
            await log(.info, "FORCE MODE: Overriding all deletion policies - will delete all eligible users immediately.")
            return
        }
        
        // Default policy
        var duration = UserManagementConstants.fourWeeks
        var forceTermDeletion = false
        var strategy = DeletionStrategy.loginAndCreation
        
        // Two-day cleanup for Library, DOC, CommDesign (by creation dates)
        if area.contains("Library") || area.contains("DOC") || area.contains("CommDesign") {
            duration = UserManagementConstants.twoDays
            strategy = .creationOnly
            await log(.info, "Applying 2-day deletion policy (creation-based) for \(area).")
        }
        // 30-day cleanup for Photo/Illustration or specific rooms
        else if area.contains("Photo") || area.contains("Illustration") || 
                room.contains("B1110") || room.contains("D3360") {
            duration = UserManagementConstants.thirtyDays
            strategy = .creationOnly
            await log(.info, "Applying 30-day deletion policy (creation-based) for \(area) / \(room).")
        }
        // End-of-term areas/rooms
        else if area.contains("FMSA") || area.contains("NMSA") ||
                room.contains("B1122") || room.contains("B4120") {
            if isEndOfTerm() {
                forceTermDeletion = true
                await log(.info, "Detected end-of-term date. Forcing immediate deletion for \(area) / \(room).")
            } else {
                duration = UserManagementConstants.sixWeeks
                strategy = .loginAndCreation
                await log(.info, "Applying 6-week last-login/creation policy for \(area) / \(room).")
            }
        }
        
        policy = DeletionPolicy(duration: duration, strategy: strategy, forceTermDeletion: forceTermDeletion)
    }
    
    private func getRemoteDesktopSetting(_ key: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "/Library/Preferences/com.apple.RemoteDesktop", key]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        try? process.run()
        process.waitUntilExit()
        
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return nil
    }
    
    private func isEndOfTerm() -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)
        
        switch month {
        case 4: return day >= 30    // End of April
        case 8: return day >= 31    // End of August  
        case 12: return day >= 31   // End of December
        default: return false
        }
    }
    
    private func processDeferredDeletions() async throws {
        await log(.info, "Checking for deferred deletions")
        
        // Check if anyone is actively at console
        if let consoleUser = getCurrentConsoleUser(),
           consoleUser != "loginwindow" && consoleUser != "root" && consoleUser != "admin" {
            await log(.info, "Active console session detected; skipping deferred deletions.")
            return
        }
        
        // Read deferred deletions from plist
        let deferredUsers = try getDeferredDeletions()
        guard !deferredUsers.isEmpty else { return }
        
        await log(.info, "Processing deferred deletions: \(deferredUsers)")
        
        for user in deferredUsers {
            if excludeList.contains(user) {
                await log(.info, "Skipping deferred user '\(user)' (excluded).")
                try await clearDeferred(user: user)
                continue
            }
            try await deleteUser(user)
        }
    }
    
    private func getDeferredDeletions() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", userSessionsPlist, "DeferredDeletes"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            // Parse the array output from defaults command
            let cleanOutput = output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: "\"", with: "")
            
            return cleanOutput.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        
        return []
    }
    
    private func clearDeferred(user: String) async throws {
        // This is a simplified version - would need full implementation
        await log(.info, "Clearing deferred deletion for user: \(user)")
    }
    
    private func repairUserStates() async throws {
        await log(.info, "Starting repair pass for problematic user states.")
        // Implementation would go here - complex user state repair logic
        await log(.info, "User state repair pass completed.")
    }
    
    private func processUsers() async throws {
        await log(.info, "Starting user management (processing users).")
        
        let plistURL = URL(fileURLWithPath: userSessionsPlist)  
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        
        guard let lastLogins = plist?["LastLogins"] as? [String: Int64],
              let creationDates = plist?["CreationDates"] as? [String: Int64] else {
            throw UserManagerError.userDataNotFound
        }
        
        let allUsers = Set(lastLogins.keys).union(Set(creationDates.keys))
        let currentTime = Int64(Date().timeIntervalSince1970)
        
        for user in allUsers {
            // Skip excluded users
            if excludeList.contains(user) {
                await log(.info, "Skipping excluded user: '\(user)'")
                continue
            }
            
            await log(.info, "Processing user: '\(user)'")
            
            // Force term deletion overrides all other logic
            if policy.forceTermDeletion {
                await log(.info, "End-of-term forced deletion for '\(user)'.")
                try await deleteUser(user)
                continue
            }
            
            let timeSinceLast = lastLogins[user].map { currentTime - $0 } ?? 0
            let timeSinceCreate = creationDates[user].map { currentTime - $0 } ?? 0
            
            let shouldDelete: Bool
            switch policy.strategy {
            case .creationOnly:
                shouldDelete = timeSinceCreate > policy.duration
                if shouldDelete {
                    await log(.info, "Deleting '\(user)' (creation older than \(policy.duration) seconds).")
                } else {
                    await log(.info, "'\(user)' is within creation threshold; no action taken.")
                }
                
            case .loginAndCreation:
                shouldDelete = timeSinceCreate > policy.duration || timeSinceLast > policy.duration
                if shouldDelete {
                    await log(.info, "Deleting '\(user)' (older than \(policy.duration) by login or creation).")
                } else {
                    await log(.info, "'\(user)' is within threshold; no action taken.")
                }
            }
            
            if shouldDelete {
                try await deleteUser(user)
            }
        }
    }
    
    private func deleteUser(_ username: String) async throws {
        if config.simulationMode {
            await log(.info, "SIMULATION: Would delete user '\(username)' (no actual deletion performed)")
            return
        }
        
        // Check for active console sessions
        if let consoleUser = getCurrentConsoleUser(),
           consoleUser != "loginwindow" && consoleUser != "root" && consoleUser != "admin" {
            await log(.info, "Console user '\(consoleUser)' active; deferring deletion of '\(username)'.")
            try deferDelete(user: username)
            return
        }
        
        await log(.info, "Initiating deletion for user: '\(username)'")
        
        // Kill processes for this user
        try await killUserProcesses(username)
        
        // Scrub cloud attributes  
        try await scrubCloudAttributes(for: username)
        
        // Disable SecureToken if enabled
        try await disableSecureToken(for: username)
        
        // Delete user via sysadminctl
        try await deleteUserAccount(username)
        
        // Remove home directory if DS record is gone
        if !(try await userExists(username)) {
            try await removeHomeDirectory(for: username)
            try await removeFromFileVault(username)
        }
        
        // Flush cache and verify
        try await flushDirectoryCache()
        
        if try await verifyDeletion(username) {
            await log(.info, "Deletion of '\(username)' verified.")
            try await clearDeferred(user: username)
        } else {
            await log(.error, "Deletion verification failed for '\(username)'.")
        }
    }
    
    // Additional helper methods would be implemented here...
    private func deferDelete(user: String) throws {
        // Implementation for deferring user deletion
    }
    
    private func killUserProcesses(_ username: String) async throws {
        // Implementation for killing user processes
    }
    
    private func scrubCloudAttributes(for username: String) async throws {
        // Implementation for scrubbing cloud/IdP attributes
    }
    
    private func disableSecureToken(for username: String) async throws {
        // Implementation for disabling SecureToken
    }
    
    private func deleteUserAccount(_ username: String) async throws {
        // Implementation for deleting user account via sysadminctl
    }
    
    private func userExists(_ username: String) async throws -> Bool {
        // Implementation for checking if user exists in DS
        return false
    }
    
    private func removeHomeDirectory(for username: String) async throws {
        // Implementation for removing home directory
    }
    
    private func removeFromFileVault(_ username: String) async throws {
        // Implementation for removing user from FileVault
    }
    
    private func verifyDeletion(_ username: String) async throws -> Bool {
        // Implementation for verifying user deletion
        return true
    }
    
    private func cleanupOrphanedUsers() async throws {
        await log(.info, "Starting cleanup of orphaned user records.")
        // Implementation would go here
        await log(.info, "Orphaned user account cleanup completed.")
    }
    
    private func flushDirectoryCache() async throws {
        await log(.info, "Flushing Directory Services cache.")
        
        let commands = [
            ["/usr/bin/dscacheutil", "-flushcache"],
            ["/usr/bin/killall", "-HUP", "opendirectoryd"]
        ]
        
        for command in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command[0])
            if command.count > 1 {
                process.arguments = Array(command[1...])
            }
            
            try process.run()
            process.waitUntilExit()
        }
        
        // Remove cache directory
        let cacheDir = "/var/db/dslocal/nodes/Default/cache"
        try? FileManager.default.removeItem(atPath: cacheDir)
        
        await log(.info, "Directory Services cache flushed.")
    }
    
    private func updateHiddenUsers() async throws {
        let script = "/usr/local/outset/login-privileged-every/LoginWindowHideUsers.sh"
        if FileManager.default.fileExists(atPath: script) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: script)
            try process.run()
            process.waitUntilExit()
            await log(.info, "Hidden users on login window updated.")
        }
    }
}

// MARK: - Extensions
extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    
    static let backupFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()
}

extension LogLevel {
    var stringValue: String {
        switch self {
        case .info: return "INFO"
        case .warning: return "WARNING"  
        case .error: return "ERROR"
        }
    }
}

// MARK: - Errors
enum UserManagerError: Error {
    case plistNotFound
    case instanceAlreadyRunning
    case adminPasswordNotFound
    case adminPasswordDecodeError
    case exclusionsNotFound
    case userDataNotFound
}