// Sources/manageusers/Config.swift

import Foundation

struct User: Codable {
    let name: String
    let lastLogin: Int64
}

enum ConfigError: Error {
    case plistConversionFailed
    case plistParsingFailed
    case plistFileNotFound
}

struct Config {
    // Base Exclusion List (System Users)
    static let baseExcludeUsers: [String] = [
        "_mbsetupuser",
        "root",
        "daemon",
        "nobody",
        "sys",
        "guest"
    ]
    
    // Custom Exclusion List (Loaded Externally)
    static var customExcludeUsers: [String] = []
    
    // Combined Exclusion List
    static var excludeUsers: [String] {
        return baseExcludeUsers + customExcludeUsers
    }
    
    // Path to the integrated UserSessions plist file
    static let userSessionsPlistPath = "/Library/Management/ca.ecuad.macadmin.UserSessions.plist"
    
    // Initialize Config by loading custom exclusions
    static func initialize() throws {
        // Load combined data from plist
        guard FileManager.default.fileExists(atPath: userSessionsPlistPath) else {
            throw ConfigError.plistFileNotFound
        }
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: userSessionsPlistPath))
            let plist = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil)
            
            guard let dict = plist as? [String: Any] else {
                throw ConfigError.plistParsingFailed
            }
            
            // Load custom exclusions
            if let exclusions = dict["Exclusions"] as? [String] {
                customExcludeUsers = exclusions
                Logger.log("Loaded custom exclusions: \(customExcludeUsers)")
            } else {
                Logger.log("No custom exclusions found in plist.")
            }
        } catch {
            Logger.log("Error loading or parsing UserSessions plist: \(error)")
            throw error
        }
    }
    
    // Check if a user is excluded
    static func isExcluded(_ user: String) -> Bool {
        return excludeUsers.contains(user)
    }
    
    // Parse the Users section from the plist and return users
    static func parseUsers(from path: String) throws -> [User] {
        let plistURL = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: plistURL)
        
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: &format)
        
        guard let dict = plist as? [String: Any],
              let usersDict = dict["Users"] as? [String: Int64] else {
            throw ConfigError.plistParsingFailed
        }
        
        var users: [User] = []
        for (name, lastLogin) in usersDict {
            users.append(User(name: name, lastLogin: lastLogin))
        }
        return users
    }
}
