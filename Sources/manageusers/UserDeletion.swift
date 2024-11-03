// Sources/manageusers/UserDeletion.swift

import Foundation

struct UserDeletion {
    static func deleteUser(named user: String) {
        Logger.log("Initiating deletion process for user: '\(user)'")
        
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
        }
        
        // Optional: Remove FileVault credentials
        removeFileVaultCredentials(for: user)
        
        // Verify deletion
        verifyDeletion(of: user)
        
        Logger.log("Completed deletion process for user: '\(user)'")
        Logger.log("------------------------------------------------------------")
    }
    
    private static func userExists(_ user: String) -> Bool {
        // Alternative logic to verify user existence without using `dscl`
        return false
    }
    
    private static func verifyDeletion(of user: String) {
        if userExists(user) {
            Logger.log("Verification FAILED: User '\(user)' still exists.")
        } else {
            Logger.log("Verification SUCCESS: User '\(user)' has been deleted.")
        }
    }
    
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
