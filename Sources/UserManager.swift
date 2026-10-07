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

// MARK: - User Manager Class
class UserManager {
    private let config: UserDeletionConfig
    private let logger: Logging.Logger
    private let lockDir = "/var/run/ManageUsers.lock"
    private let managementLog = ManagementLog.shared
    private let userSessionsPlist = "/Library/Management/Cache/UserSessions.plist"

    private var excludeList: [String] = []
    private var currentUsers: [String] = []
    private var policy: DeletionPolicy!
    private var protection = AccountProtection(exclusions: [])
    private let inspector = AccountInspector()
    private var volumeUsers: [AccountInspector.VolumeUser] = []
    private var adminVolumeOwners: Set<String> = []
    private var deletedCount = 0
    private var failedCount = 0
    private var plannedDeletions: [(name: String, reason: String)] = []
    private let preferences: ManageUsersPreferences

    init(config: UserDeletionConfig, preferences: ManageUsersPreferences = .system) {
        self.config = config
        self.preferences = preferences
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        self.logger = Logging.Logger(label: "UserManager")
    }

    func run() async throws {
        await log(.info, "===== ManageUsers started =====")
        await log(.info, "Log file: \(managementLog.path)")
        await log(.info, "UserSessions plist: \(userSessionsPlist)")

        switch Self.sessionsFileState(at: userSessionsPlist) {
        case .missing:
            // A Mac that has never tracked sessions has no plist. That is a normal
            // state: nothing is evaluated, so nothing can be deleted, and the run
            // succeeds. No other age source stands in for the missing data.
            await log(.info, "No sessions tracked yet (\(userSessionsPlist) does not exist); no account was evaluated or deleted.")
            await log(.info, "===== ManageUsers completed =====")
            if config.printPlan {
                print(Self.planLine([]))
            }
            return
        case .untrusted:
            // The plist decides who is excluded from deletion, so act on it only
            // when root alone could have written it.
            await log(.error, "UserSessions plist at \(userSessionsPlist) is not owned by root or is writable by another account; refusing to use it.")
            throw UserManagerError.untrustedSessionsPlist
        case .present:
            break
        }

        await log(.info, "UserSessions plist found")
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
        
        // Load exclusions, admin protection and policies
        try await loadExclusions()
        loadProtection()
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
        
        await log(.info, "Run summary: \(deletedCount) deleted, \(failedCount) failed\(config.simulationMode ? " (simulation)" : "").")
        await log(.info, "===== ManageUsers completed =====")
        if config.printPlan {
            print(Self.planLine(plannedDeletions))
        }
        if failedCount > 0 { throw UserManagerError.deletionsFailed(failedCount) }
    }
    
    enum SessionsFileState: Equatable {
        /// Nothing at the path: no sessions have been tracked yet.
        case missing
        /// Something is there, but not a file only root could have written.
        case untrusted
        /// A trusted file. It may still fail to read or parse, which is an error.
        case present
    }

    /// Classifies the sessions plist without following a link, so a dangling
    /// link counts as untrusted rather than missing.
    static func sessionsFileState(at path: String) -> SessionsFileState {
        var info = stat()
        if lstat(path, &info) != 0 {
            return errno == ENOENT ? .missing : .untrusted
        }
        return FileTrust.isTrustedFile(path) ? .present : .untrusted
    }

    /// One line a caller can parse: the accounts this simulation would delete.
    static func planLine(_ planned: [(name: String, reason: String)]) -> String {
        let accounts = planned.map { ["name": $0.name, "reason": $0.reason] }
        let data = (try? JSONSerialization.data(withJSONObject: ["accounts": accounts], options: [.sortedKeys])) ?? Data("{\"accounts\":[]}".utf8)
        return "MANAGEUSERS_PLAN " + (String(data: data, encoding: .utf8) ?? "{\"accounts\":[]}")
    }

    private func log(_ level: LogLevel, _ message: String) async {
        managementLog.write(level, message)
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
    
    private func loadExclusions() async throws {
        await log(.info, "Loading exclusions from \(userSessionsPlist)")
        
        let plistURL = URL(fileURLWithPath: userSessionsPlist)
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        
        guard let exclusions = plist?["Exclusions"] as? [String] else {
            throw UserManagerError.exclusionsNotFound
        }
        
        // Combine with always excluded users
        let configured = preferences.additionalExclusions()
        excludeList = Array(Set(exclusions + configured + UserManagementConstants.alwaysExcludedUsers))
        if !configured.isEmpty {
            await log(.info, "Added configured exclusions: \(configured)")
        }
        
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

    private func loadProtection() {
        let settings = AdminGuardSettings.load()
        protection = AccountProtection(
            exclusions: excludeList,
            deleteAdmins: settings.deleteAdmins,
            deletableAdmins: settings.deletableAdmins.filter { name in
                !excludeList.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
        )
        volumeUsers = inspector.volumeUsers()
        adminVolumeOwners = inspector.adminVolumeOwners(volumeUsers: volumeUsers)
        if settings.deleteAdmins {
            managementLog.write(.warning, "Admin protection is OFF (DeleteAdmins is true): admin accounts may be deleted")
        } else {
            managementLog.write(.info, "Admin protection is on: members of the admin group are never deleted")
            if !protection.deletableAdmins.isEmpty {
                managementLog.write(.info, "Admins opted in to deletion (DeletableAdmins): \(protection.deletableAdmins.sorted())")
            }
        }
        managementLog.write(.info, "Admin volume owners on the boot volume: \(adminVolumeOwners.sorted())")
    }

    /// Asks the evaluator about one account. Every deletion path goes through here.
    private func decide(_ user: String, lastLogin: Date?, recordedCreation: Date?) -> DeletionDecision {
        let facts = inspector.facts(for: user, lastLogin: lastLogin, recordedCreation: recordedCreation, volumeUsers: volumeUsers)
        let remaining = adminVolumeOwners.subtracting([user]).count
        let decision = DeletionEvaluator.evaluate(facts, policy: policy, protection: protection, adminVolumeOwnersRemaining: remaining)
        if decision.shouldDelete, let only = config.onlyAccounts, !only.contains(user.lowercased()) {
            return .keep("not in the confirmed list for this run")
        }
        return decision
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
            await log(.info, "FORCE MODE: the age threshold is zero; exclusions and admin protection still apply.")
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
        
        // A --days or --strategy flag for this run, else a configured setting
        // (a profile-forced value first), replaces the area-derived value.
        if let days = preferences.deletionDays(flag: config.customDays) {
            duration = days * 24 * 60 * 60
            forceTermDeletion = false
            await log(.info, "Using configured deletion threshold of \(days) days.")
        }
        if let configuredStrategy = preferences.deletionStrategy(flag: config.customStrategy) {
            strategy = configuredStrategy
            await log(.info, "Using configured deletion strategy \(configuredStrategy).")
        }

        policy = DeletionPolicy(duration: duration, strategy: strategy, forceTermDeletion: forceTermDeletion)
    }
    
    private func getRemoteDesktopSetting(_ key: String) -> String? {
        // Through CFPreferences rather than the plist on disk, so a value set by a
        // configuration profile counts as well.
        managedStringPreference(key, domain: "com.apple.RemoteDesktop")
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
            guard inspector.exists(user) else {
                await log(.info, "Deferred user '\(user)' no longer exists.")
                continue
            }
            let decision = decide(user, lastLogin: nil, recordedCreation: nil)
            guard decision.shouldDelete else {
                await log(.info, "Keeping deferred user '\(user)': \(decision.reason).")
                continue
            }
            try await deleteUser(user, reason: decision.reason)
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
    
    private func repairUserStates() async throws {
        // Not implemented yet; the shell version's repair pass is still the one in use.
        await log(.debug, "User state repair is not implemented in this version; skipped.")
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

        for user in allUsers.sorted() {
            guard inspector.exists(user) else {
                await log(.debug, "'\(user)' has no account any more; nothing to delete.")
                continue
            }
            let decision = decide(
                user,
                lastLogin: lastLogins[user].map { Date(timeIntervalSince1970: TimeInterval($0)) },
                recordedCreation: creationDates[user].map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
            if decision.shouldDelete {
                await log(.info, "Delete '\(user)': \(decision.reason).")
                try await deleteUser(user, reason: decision.reason)
            } else {
                await log(.info, "Keep '\(user)': \(decision.reason).")
            }
        }
    }
    
    private func deleteUser(_ username: String, reason: String) async throws {
        if config.simulationMode {
            plannedDeletions.append((username, reason))
            await log(.info, "SIMULATION: would delete '\(username)' (\(reason)); nothing was changed.")
            return
        }

        // Someone at the console: leave deletions for a later run. The next run
        // evaluates the account again, so nothing is lost by waiting.
        if let consoleUser = getCurrentConsoleUser(),
           consoleUser != "loginwindow" && consoleUser != "root" && consoleUser != "admin" {
            await log(.info, "Console user '\(consoleUser)' active; deletion of '\(username)' left for a later run.")
            return
        }

        await log(.info, "Deleting '\(username)'.")
        let deleter = UserDeleter(log: { level, message in ManagementLog.shared.write(level, message) })
        do {
            try deleter.delete(username)
            deletedCount += 1
            await log(.info, "Deletion of '\(username)' verified: no record, no home folder, no volume user.")
        } catch {
            failedCount += 1
            await log(.error, "\(error)")
        }
    }

    /// Accounts with no home folder go through the same evaluator as everyone
    /// else, using their directory creation date. No login is recorded for
    /// them, which counts as "never".
    private func cleanupOrphanedUsers() async throws {
        await log(.info, "Checking accounts that have no home folder.")
        for user in inspector.localUserNames().sorted() {
            guard !FileManager.default.fileExists(atPath: "/Users/\(user)") else { continue }
            let decision = decide(user, lastLogin: nil, recordedCreation: nil)
            if decision.shouldDelete {
                await log(.info, "Delete orphaned account '\(user)': \(decision.reason).")
                try await deleteUser(user, reason: decision.reason)
            } else {
                await log(.info, "Keep orphaned account '\(user)': \(decision.reason).")
            }
        }
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

// MARK: - Errors
enum UserManagerError: Error {
    case instanceAlreadyRunning
    case exclusionsNotFound
    case userDataNotFound
    case deletionsFailed(Int)
    case untrustedSessionsPlist
}