// Sources/manageusers/main.swift

import Foundation

// Define acceptable durations
enum Duration: Int {
    case oneWeek = 1
    case fourWeeks = 4

    var timeInterval: TimeInterval {
        switch self {
        case .oneWeek:
            return 7 * 24 * 60 * 60 // 1 week in seconds
        case .fourWeeks:
            return 28 * 24 * 60 * 60 // 4 weeks in seconds
        }
    }
}

// Initialize Logger
do {
    try Logger.initialize(logPath: "/Library/Management/Logs/manageusers.log")
} catch {
    print("Failed to initialize logger: \(error)")
    exit(1)
}

Logger.log("===== manageusers started =====")

// Initialize Config by loading custom exclusions
do {
    try Config.initialize()
} catch {
    Logger.log("Failed to initialize configuration: \(error)")
    exit(1)
}

// Parse Command-Line Arguments for Duration
let arguments = CommandLine.arguments
var duration: Duration?

for (index, arg) in arguments.enumerated() {
    if arg == "--duration", index + 1 < arguments.count {
        if let weeks = Duration(rawValue: Int(arguments[index + 1]) ?? 0) {
            duration = weeks
        } else {
            Logger.log("Invalid duration value: \(arguments[index + 1]). Use '1' for 1 week or '4' for 4 weeks.")
            exit(1)
        }
    }
}

guard let selectedDuration = duration else {
    Logger.log("Duration not specified. Usage: manageusers --duration [1|4]")
    exit(1)
}

Logger.log("Selected duration: \(selectedDuration.rawValue) week(s)")

// Parse plist
let plistPath = Config.userSessionsPlistPath
let users: [User]
do {
    users = try Config.parseUsers(from: plistPath)
} catch {
    Logger.log("Error parsing plist: \(error)")
    exit(1)
}

// Current Time
let currentTime = Date()

// Process Each User
for user in users {
    Logger.log("Processing user: '\(user.name)' with last login time: '\(user.lastLogin)'")
    
    // Skip Excluded Users
    if Config.isExcluded(user.name) {
        Logger.log("Skipping excluded user: '\(user.name)'")
        continue
    }
    
    // Validate Last Login Time
    guard user.lastLogin > 0 else {
        Logger.log("Skipping user '\(user.name)': Invalid or missing last login time.")
        continue
    }
    
    // Calculate Time Since Last Login
    let lastLoginDate = Date(timeIntervalSince1970: TimeInterval(user.lastLogin))
    let timeSinceLastLogin = currentTime.timeIntervalSince(lastLoginDate)
    
    // Compare with Duration
    if timeSinceLastLogin > selectedDuration.timeInterval {
        Logger.log("User '\(user.name)' has not logged in for more than \(selectedDuration.rawValue) week(s). Initiating deletion.")
        UserDeletion.deleteUser(named: user.name)
    } else {
        Logger.log("User '\(user.name)' logged in within the last \(selectedDuration.rawValue) week(s). No action taken.")
    }
}

// Flush Directory Services Cache
FlushDSCache.flush()

Logger.log("===== manageusers completed =====")
exit(0)
