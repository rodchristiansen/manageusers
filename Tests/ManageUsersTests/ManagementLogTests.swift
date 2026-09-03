import Testing
import Foundation
@testable import manageusers

@Suite("ManagementLog")
struct ManagementLogTests {

    private func temporaryDirectory() -> String {
        let path = NSTemporaryDirectory() + "manageusers-log-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("Records go to a day directory beside a structured event stream")
    func dayNestedLayout() throws {
        let directory = temporaryDirectory()
        let log = ManagementLog(directory: directory, legacyDirectory: directory + "/nonexistent")
        log.echoToConsole = false

        log.info("created account for a lab session")
        log.error("could not remove the home directory")

        let day = ManagementLog.dayFormatter.string(from: Date())
        #expect(log.path == directory + "/" + day + "/manageusers.log")

        let lines = try String(contentsOfFile: log.path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("] INFO  created account for a lab session"))

        let events = try String(contentsOfFile: directory + "/" + day + "/events.jsonl", encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(events.count == 2)
        let second = try #require(try JSONSerialization.jsonObject(with: Data(events[1].utf8)) as? [String: String])
        #expect(second["level"] == "ERROR")
        #expect(second["event_type"] == "error")
        #expect(second["tool"] == "manageusers")
        #expect(second["message"] == "could not remove the home directory")
    }

    @Test("Retention removes day directories and the flat log this layout replaced")
    func retention() throws {
        let directory = temporaryDirectory()
        let fm = FileManager.default
        let stale = Date().addingTimeInterval(-60 * 24 * 60 * 60)
        try fm.createDirectory(atPath: directory + "/" + ManagementLog.dayFormatter.string(from: stale),
                               withIntermediateDirectories: true)
        for name in ["manageusers.log", "manageusers.log.3"] {
            fm.createFile(atPath: directory + "/" + name, contents: Data("old\n".utf8))
            try fm.setAttributes([.modificationDate: stale], ofItemAtPath: directory + "/" + name)
        }

        let log = ManagementLog(directory: directory, legacyDirectory: directory + "/nonexistent")
        log.echoToConsole = false
        log.info("first record of the day")

        let day = ManagementLog.dayFormatter.string(from: Date())
        #expect(try Set(fm.contentsOfDirectory(atPath: directory)) == [day])
    }
}
