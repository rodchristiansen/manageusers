// Sources/manageusers/FlushDSCache.swift

import Foundation

struct FlushDSCache {
    static func flush() {
        Logger.log("Flushing Directory Services cache.")
        let output = runCommand("/usr/bin/dscacheutil", arguments: ["-flushcache"])
        
        if output.isEmpty {
            Logger.log("Successfully flushed Directory Services cache.")
        } else {
            Logger.log("Failed to flush Directory Services cache. Output: \(output)")
        }
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
}
