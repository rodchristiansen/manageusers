// Sources/manageusers/Config.swift

import Foundation

struct User: Codable {
    let name: String
    let lastLogin: Int64
}

enum ConfigError: Error {
    case plistConversionFailed
    case plistParsingFailed
}

struct Config {
    // Exclusion list
    static let excludeUsers: [String] = [
        "_mbsetupuser",
        "root",
        "daemon",
        "nobody",
        "sys",
        "guest",
        "admin",
        "doc",
        "cts",
        "fvim",
        "fmsa"
    ]
    
    // Check if a user is excluded
    static func isExcluded(_ user: String) -> Bool {
        return excludeUsers.contains(user)
    }
    
    // Parse the plist file and return users
    static func parsePlist(at path: String) throws -> [User] {
        let plistURL = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: plistURL)
        
        var format = PropertyListSerialization.PropertyListFormat.xml
        let plist = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: &format)
        
        guard let dict = plist as? [String: Any],
              let userDict = dict["Users"] as? [String: Int64] else {
            throw ConfigError.plistParsingFailed
        }
        
        var users: [User] = []
        for (name, lastLogin) in userDict {
            users.append(User(name: name, lastLogin: lastLogin))
        }
        return users
    }
}
