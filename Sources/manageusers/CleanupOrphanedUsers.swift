// Sources/manageusers/CleanupOrphanedUsers.swift

import Foundation

struct CleanupOrphanedUsers {
    static func cleanup() {
        Logger.log("Starting cleanup of orphaned user records (users without home directories).")
        
        // Get list of all users excluding system accounts
        let users = getAllUsers()
        
        for user in users {
            // Skip excluded users and system users
            if Config.isExcluded(user) || user.hasPrefix("_") {
                continue
            }
            
            // Get home directory
            let homeDir = getUserHomeDir(user)
            
            if homeDir.isEmpty || !directoryExists(homeDir) {
                Logger.log("User '\(user)' has no home directory at '\(homeDir)'. Attempting to delete record...")
                UserDeletion.deleteUser(named: user)
            } else {
                Logger.log("User '\(user)' has a home directory at '\(homeDir)'. Skipping deletion.")
            }
        }
        
        Logger.log("Completed cleanup of orphaned user records.")
        Logger.log("------------------------------------------------------------")
    }
    
    // Retrieve all users from system records
    private static func getAllUsers() -> [String] {
        let output = runCommand("/usr/bin/dscl", arguments: [".", "list", "/Users"])
        let users = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return users.filter { !$0.isEmpty }
    }
    
    // Execute a shell command and return its output
    private static func runCommand(_ path: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
        } catch {
            Logger.log("Failed to execute command: \(path) \(arguments.joined(separator: " "))")
            return ""
        }
        
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // Get user's home directory
    private static func getUserHomeDir(_ user: String) -> String {
        let output = runCommand("/usr/bin/dscl", arguments: [".", "-read", "/Users/\(user)", "NFSHomeDirectory"])
        let parts = output.components(separatedBy: " ")
        if parts.count >= 2 {
            return parts[1]
        }
        return ""
    }
    
    // Check if a directory exists
    private static func directoryExists(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/test")
        process.arguments = ["-d", path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
        } catch {
            Logger.log("Failed to execute test for directory existence: \(path)")
            return false
        }
        
        process.waitUntilExit()
        
        return process.terminationStatus == 0
    }
}
