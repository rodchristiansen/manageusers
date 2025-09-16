import Foundation
import Logging
import OSLog

// MARK: - UTMPX Constants and Structures
private let BOOT_TIME: Int16 = 2
private let USER_PROCESS: Int16 = 7  
private let DEAD_PROCESS: Int16 = 8
private let SHUTDOWN_TIME: Int16 = 11

private struct timeval {
    let tv_sec: Int64   // seconds since the epoch
    let tv_usec: Int32  // microseconds
}

private struct utmpx {
    let ut_user: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,  // 256 bytes for username
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)
    let ut_id: (Int8, Int8, Int8, Int8)      // 4 bytes
    let ut_line: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,    // 32 bytes for terminal line
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)
    let ut_pid: Int32
    let ut_type: Int16
    let ut_tv: timeval
    let ut_host: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,    // 256 bytes for host
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                  Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)
    let ut_pad: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                 UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)  // 16 UInt32s
}

// MARK: - Session Event Structure  
struct SessionEvent {
    let event: String
    let user: String?
    let time: Int64
    let uid: String?
    let remoteHost: String?
    
    init(event: String, user: String? = nil, time: Int64, uid: String? = nil, remoteHost: String? = nil) {
        self.event = event
        self.user = user  
        self.time = time
        self.uid = uid
        self.remoteHost = remoteHost
    }
}

// MARK: - Session Tracker Class
class SessionTracker {
    private let config: SessionTrackingConfig
    private let logger: Logger
    
    // Default exclusion list matching the Python script
    private let customExcludeUsers = [
        "admin", "student", "doc", "cts", "fvim", "fmsa"
    ]
    
    init(config: SessionTrackingConfig) {
        self.config = config
        self.logger = Logger(label: "SessionTracker")
    }
    
    func run() async throws {
        logger.info("Starting SessionTracker")
        
        let events = try await getSessionEvents()
        let currentUsers = try getCurrentUsers()
        
        // Process last login times
        var userSigninLog: [String: Int64] = [:]
        for event in events {
            if event.event == "login", 
               let username = event.user,
               currentUsers.contains(username) {
                let lastLoginTime = event.time
                if userSigninLog[username] == nil || lastLoginTime > userSigninLog[username]! {
                    userSigninLog[username] = lastLoginTime
                }
            }
        }
        
        // Collect creation times
        var userCreationLog: [String: Int64] = [:]
        for username in currentUsers {
            if let timestamp = try await getAccountCreationTimestamp(for: username) {
                userCreationLog[username] = timestamp
            }
        }
        
        let combinedData: [String: Any] = [
            "LastLogins": userSigninLog,
            "CreationDates": userCreationLog,
            "Exclusions": customExcludeUsers
        ]
        
        let outputPath = config.outputPath ?? "/Library/Management/Cache/UserSessions.plist"
        try await writePlist(data: combinedData, to: outputPath)
        
        logger.info("Successfully wrote combined plist to \(outputPath)")
    }
    
    private func getSessionEvents() async throws -> [SessionEvent] {
        logger.info("Starting session event collection")
        
        var events: [SessionEvent] = []
        
        // Use Process to call the 'last' command as a fallback if direct utmpx reading fails
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/last")
        process.arguments = ["-f", "/var/log/wtmp"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        // Parse 'last' command output
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.isEmpty { continue }
            
            // Parse last command output format
            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if components.count >= 4 {
                let username = components[0]
                let terminal = components[1]
                
                // Skip system users and excluded users
                if username == "_mbsetupuser" || username == "root" || customExcludeUsers.contains(username) {
                    continue
                }
                
                // Filter based on session type
                if config.sessionType == "gui" && terminal != "console" {
                    continue
                }
                
                // Try to extract timestamp (this is simplified - real parsing would be more complex)
                if let uid = try? await getUID(for: username) {
                    let event = SessionEvent(
                        event: "login",
                        user: username,
                        time: Int64(Date().timeIntervalSince1970), // Simplified - would need proper parsing
                        uid: uid,
                        remoteHost: nil
                    )
                    events.append(event)
                }
            }
        }
        
        logger.debug("Total events collected: \(events.count)")
        return events
    }
    
    private func getCurrentUsers() throws -> [String] {
        let usersURL = URL(fileURLWithPath: "/Users")
        let userDirectories = try FileManager.default.contentsOfDirectory(atPath: usersURL.path)
        
        return userDirectories.filter { dirname in
            !dirname.hasPrefix("_") && !customExcludeUsers.contains(dirname)
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
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output
        }
        
        return nil
    }
    
    private func getAccountCreationTimestamp(for username: String) async throws -> Int64? {
        logger.debug("Getting creation timestamp for user: \(username)")
        
        // Method 1: Try dscl for CreateTimeStamp and _xcreds_creationDate
        if let timestamp = try await getDsclCreationTimestamp(for: username) {
            return timestamp
        }
        
        // Method 2: Try accountPolicyData
        if let timestamp = try await getAccountPolicyCreationTime(for: username) {
            return timestamp  
        }
        
        // Method 3: Try local plist file
        if let timestamp = try await getLocalPlistCreationTime(for: username) {
            return timestamp
        }
        
        logger.debug("No creation timestamp found for user: \(username)")
        return nil
    }
    
    private func getDsclCreationTimestamp(for username: String) async throws -> Int64? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = [".", "read", "/Users/\(username)"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else { return nil }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        // Check for _xcreds_creationDate (Format: 2025-01-13T17:25:40Z)
        if let regex = try? NSRegularExpression(pattern: "_xcreds_creationDate:\\s*([\\d\\-T:]+Z)"),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {
            let xCredsStr = String(output[Range(match.range(at: 1), in: output)!])
            if let date = ISO8601DateFormatter().date(from: xCredsStr) {
                return Int64(date.timeIntervalSince1970)
            }
        }
        
        // Check for CreateTimeStamp (Format: 20230305121017Z)
        if let regex = try? NSRegularExpression(pattern: "CreateTimeStamp:\\s*(\\d{14})Z"),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {
            let stampStr = String(output[Range(match.range(at: 1), in: output)!])
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMddHHmmss"
            if let date = formatter.date(from: stampStr) {
                return Int64(date.timeIntervalSince1970)
            }
        }
        
        return nil
    }
    
    private func getAccountPolicyCreationTime(for username: String) async throws -> Int64? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = [".", "read", "/Users/\(username)", "accountPolicyData"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else { return nil }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        // Try extracting creationTime as <real> from XML
        if let regex = try? NSRegularExpression(pattern: "<key>creationTime</key>\\s*<real>(.*?)</real>"),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {
            let creationFloat = String(output[Range(match.range(at: 1), in: output)!])
            if let timestamp = Double(creationFloat) {
                return Int64(timestamp)
            }
        }
        
        return nil
    }
    
    private func getLocalPlistCreationTime(for username: String) async throws -> Int64? {
        let plistPath = "/private/var/db/dslocal/nodes/Default/users/\(username).plist"
        let plistURL = URL(fileURLWithPath: plistPath)
        
        guard FileManager.default.fileExists(atPath: plistPath) else { return nil }
        
        do {
            let data = try Data(contentsOf: plistURL)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            
            // Check for _xcreds_creationDate
            if let xCredsArray = plist?["_xcreds_creationDate"] as? [String],
               let xCredsStr = xCredsArray.first {
                if let date = ISO8601DateFormatter().date(from: xCredsStr) {
                    return Int64(date.timeIntervalSince1970)
                }
            }
            
            // Check for accountPolicyData
            if let apdData = plist?["accountPolicyData"] as? Data {
                let nestedPlist = try PropertyListSerialization.propertyList(from: apdData, options: [], format: nil) as? [String: Any]
                if let creationTime = nestedPlist?["creationTime"] {
                    if let timestamp = creationTime as? Double {
                        return Int64(timestamp)
                    } else if let timeStr = creationTime as? String {
                        if let date = ISO8601DateFormatter().date(from: timeStr) {
                            return Int64(date.timeIntervalSince1970)
                        }
                    }
                }
            }
            
        } catch {
            logger.error("Error reading local plist for \(username): \(error)")
        }
        
        return nil
    }
    
    private func writePlist(data: [String: Any], to path: String) async throws {
        let url = URL(fileURLWithPath: path)
        
        // Create directory if needed
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        let plistData = try PropertyListSerialization.data(fromPropertyList: data, format: .xml, options: 0)
        try plistData.write(to: url)
    }
}