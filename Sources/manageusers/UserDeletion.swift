// Sources/manageusers/UserDeletion.swift

import Foundation

struct UserDeletion {
    static func deleteUser(named user: String) {
        Logger.log("Initiating deletion process for user: '\(user)'")
        
        // Check if user exists
        if !userExists(user) {
            Logger.log("User '\(user)' does not exist. Skipping deletion.")
            return
        }
        
        // Attempt to delete using sysadminctl
        let sysadminOutput = runCommand("/usr/sbin/sysadminctl", arguments: ["-deleteUser", user, "-secure"])
        if sysadminOutput.contains("Securely removing") {
            Logger.log("Successfully deleted user via sysadminctl: '\(user)'")
        } else {
            Logger.log("sysadminctl FAILED to delete user: '\(user)'. Output: \(sysadminOutput)")
            Logger.log("Proceeding with dscl deletion.")
        }
        
        // Attempt to delete using dscl
        let dsclOutput = runCommand("/usr/bin/dscl", arguments: [".", "-delete", "/Users/\(user)"])
        if dsclOutput.isEmpty {
            Logger.log("Successfully deleted user via dscl: '\(user)'")
        } else {
            if userExists(user) {
                Logger.log("dscl FAILED to delete user: '\(user)'. Output: \(dsclOutput)")
            } else {
                Logger.log("User '\(user)' does not exist in DS. No action needed.")
            }
        }
        
        // Optional: Remove FileVault credentials
        removeFileVaultCredentials(for: user)
        
        // Verify deletion
        verifyDeletion(of: user)
        
        Logger.log("Completed deletion process for user: '\(user)'")
        Logger.log("------------------------------------------------------------")
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
    
    // Check if a user exists
    private static func userExists(_ user: String) -> Bool {
        let output = runCommand("/usr/bin/dscl", arguments: [".", "-read", "/Users/\(user)"])
        return !output.isEmpty
    }
    
    // Verify if the user has been deleted
    private static func verifyDeletion(of user: String) {
        if userExists(user) {
            Logger.log("Verification FAILED: User '\(user)' still exists.")
        } else {
            Logger.log("Verification SUCCESS: User '\(user)' has been deleted.")
        }
    }
    
    // Remove FileVault credentials for a user, if applicable
    private static func removeFileVaultCredentials(for user: String) {
        let fdeList = runCommand("/usr/bin/fdesetup", arguments: ["list"])
        if fdeList.contains(user) {
            let removeOutput = runCommand("/usr/bin/fdesetup", arguments: ["remove", "-user", user])
            if removeOutput.isEmpty {
                Logger.log("Successfully removed FileVault credentials for user: '\(user)'")
            } else {
                Logger.log("Failed to remove FileVault credentials for user: '\(user)'. Output: \(removeOutput)")
            }
        }
    }
}
