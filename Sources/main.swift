import ArgumentParser
import Foundation
import Logging

// MARK: - Configuration Structures
struct UserDeletionConfig {
    let simulationMode: Bool
    let forceMode: Bool 
    let verboseLogging: Bool
    let customDays: Int?
    let customExclusionsPlist: String?
    let customStrategy: String?
}

struct SessionTrackingConfig {
    let verboseLogging: Bool
    let sessionType: String
    let outputPath: String?
    let generateOnly: Bool
}

// MARK: - Delete Users Command
struct DeleteUsers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Manage user deletions based on inactivity policies"
    )
    
    @Flag(name: .shortAndLong, help: "Enable simulation mode (no actual deletions)")
    var simulate = false
    
    @Flag(name: .shortAndLong, help: "Enable force mode (bypass time restrictions)")  
    var force = false
    
    @Flag(name: .shortAndLong, help: "Disable simulation mode (perform actual deletions)")
    var live = false
    
    @Flag(name: [.customShort("v"), .long], help: "Enable verbose logging")
    var verbose = false
    
    @Option(help: "Override duration threshold in days")
    var days: Int?
    
    @Option(help: "Path to custom exclusions plist")
    var exclusionsPlist: String?
    
    @Option(help: "Deletion strategy: login-and-creation, creation-only")
    var strategy: String?
    
    mutating func run() async throws {
        let config = UserDeletionConfig(
            simulationMode: simulate || !live,
            forceMode: force,
            verboseLogging: verbose,
            customDays: days,
            customExclusionsPlist: exclusionsPlist,
            customStrategy: strategy
        )
        
        let manager = UserManager(config: config)
        try await manager.run()
    }
}

// MARK: - User Sessions Command  
struct UserSessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "Track and analyze user login sessions"
    )
    
    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose = false
    
    @Option(help: "Session type to track: gui, ssh, gui_ssh")
    var sessionType: String = "gui_ssh"
    
    @Option(help: "Output plist path")  
    var output: String?
    
    @Flag(help: "Only generate session data without user management")
    var generateOnly = false
    
    mutating func run() async throws {
        let config = SessionTrackingConfig(
            verboseLogging: verbose,
            sessionType: sessionType,
            outputPath: output,
            generateOnly: generateOnly
        )
        
        let tracker = SessionTracker(config: config)
        try await tracker.run()
    }
}

// MARK: - Remediation Subcommands
struct CheckSecureToken: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secure-token", 
        abstract: "Check SecureToken status for all users"
    )
    
    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose = false
    
    @Argument(help: "Specific username to check (optional)")
    var username: String?
    
    mutating func run() async throws {
        let remediation = RemediationManager(verbose: verbose)
        try await remediation.checkSecureToken(for: username)
    }
}

struct CleanupOrphans: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup-orphans",
        abstract: "Clean up orphaned user records and home directories"  
    )
    
    @Flag(name: .shortAndLong, help: "Enable simulation mode")
    var simulate = false
    
    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose = false
    
    @Option(help: "Cleanup type: dscl-orphans, home-orphans, both")
    var type: String = "both"
    
    mutating func run() async throws {
        let remediation = RemediationManager(verbose: verbose)
        try await remediation.cleanupOrphans(type: type, simulate: simulate)
    }
}

struct CountUsers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "count",
        abstract: "Count GUI users vs dscl users"
    )
    
    @Flag(name: .shortAndLong, help: "List usernames instead of just counting")
    var list = false
    
    mutating func run() async throws {
        let remediation = RemediationManager(verbose: false)
        try await remediation.countUsers(listUsers: list)
    }
}

struct ListUsers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List users and their properties"
    )
    
    @Option(help: "Filter type: all, gui, dscl, excluded")
    var filter: String = "all"
    
    @Flag(help: "Include additional user details")
    var details = false
    
    mutating func run() async throws {
        let remediation = RemediationManager(verbose: false)
        try await remediation.listUsers(filter: filter, includeDetails: details)
    }
}

struct DeleteAllUsers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-all",
        abstract: "Delete all non-excluded users (DANGEROUS)"
    )
    
    @Flag(name: .shortAndLong, help: "Enable simulation mode")
    var simulate = false
    
    @Flag(name: .shortAndLong, help: "Skip confirmation prompt")
    var force = false
    
    @Option(help: "Admin password (use with caution)")
    var password: String?
    
    mutating func run() async throws {
        let remediation = RemediationManager(verbose: true)
        try await remediation.deleteAllUsers(simulate: simulate, force: force, password: password)
    }
}

struct ManageXCreds: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcreds",
        abstract: "Manage XCreds authentication system"
    )
    
    @Option(help: "Action: load, unload, uninstall, status")
    var action: String = "status"
    
    @Flag(name: .shortAndLong, help: "Enable verbose output")  
    var verbose = false
    
    mutating func run() async throws {
        let remediation = RemediationManager(verbose: verbose)
        try await remediation.manageXCreds(action: action)
    }
}

struct FlushCache: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flush-cache",
        abstract: "Flush directory services and system caches"
    )
    
    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose = false
    
    mutating func run() async throws {
        let remediation = RemediationManager(verbose: verbose)
        try await remediation.flushDirectoryCache()
    }
}

// MARK: - Remediation Command
struct Remediation: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remediate",
        abstract: "Run system remediation and maintenance tasks",
        subcommands: [
            CheckSecureToken.self,
            CleanupOrphans.self,
            CountUsers.self,
            ListUsers.self,
            DeleteAllUsers.self,
            ManageXCreds.self,
            FlushCache.self,
        ]
    )
}

// MARK: - Main Command  
struct ManageUsers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "SharedDevice User Management Tool",
        discussion: """
        A comprehensive user management tool for shared macOS devices.
        Handles user deletion, session tracking, and system maintenance
        with support for simulation, force modes, and remediation tasks.
        """,
        version: "2.0.0",
        subcommands: [
            DeleteUsers.self,
            UserSessions.self,
            Remediation.self,
        ],
        defaultSubcommand: DeleteUsers.self
    )
}

// Entry point
await ManageUsers.main()