// Sources/manageusers/Logger.swift

import Foundation

struct Logger {
    static let logFileHandle: FileHandle? = {
        let logPath = "/Library/Management/Logs/manageusers.log"
        let logURL = URL(fileURLWithPath: logPath)
        let logDir = logURL.deletingLastPathComponent()
        
        // Create log directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        } catch {
            print("Failed to create log directory: \(error)")
            return nil
        }
        
        // Create or append to log file
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        
        do {
            let fileHandle = try FileHandle(forWritingTo: logURL)
            return fileHandle
        } catch {
            print("Failed to open log file: \(error)")
            return nil
        }
    }()
    
    static func initialize(logPath: String) throws {
        // Initialization is handled in the logFileHandle's closure
        // Ensure the logFileHandle is ready
        if logFileHandle == nil {
            throw NSError(domain: "Logger", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize log file."])
        }
    }
    
    static func log(_ message: String) {
        let timestamp = getCurrentTimestamp()
        let logMessage = "[\(timestamp)] \(message)\n"
        
        if let data = logMessage.data(using: .utf8) {
            logFileHandle?.seekToEndOfFile()
            logFileHandle?.write(data)
        }
        
        // Also print to stdout for immediate feedback (optional)
        print(logMessage, terminator: "")
    }
    
    private static func getCurrentTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
