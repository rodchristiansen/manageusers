//
//  LogSessionStore.swift
//  Managed Users Cleanup
//
//  Lists manageusers' logs under /Library/Managed Users/logs. Each day is a
//  directory, YYYY-MM-DD/, holding manageusers.log beside events.jsonl. The flat
//  manageusers.log and its rolled generations at the root predate that layout
//  and are still listed.
//

import Foundation

struct LogSession: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let date: Date?
    let size: Int64

    var displayDate: String {
        guard let date else { return name }
        return LogSessionStore.displayDateFormatter.string(from: date)
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

enum LogSessionStore {
    static let logFileName = "manageusers.log"

    static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parseDay(_ name: String) -> Date? {
        dayFormatter.date(from: name)
    }

    /// Every day's log under `root`, newest first, then any flat legacy logs.
    static func sessions(in root: String, fileManager fm: FileManager = .default) -> [LogSession] {
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }

        var found: [LogSession] = []
        for entry in entries {
            let entryPath = (root as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entryPath, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                guard let day = parseDay(entry) else { continue }
                let path = (entryPath as NSString).appendingPathComponent(logFileName)
                guard fm.fileExists(atPath: path) else { continue }
                found.append(LogSession(id: entry, name: entry, path: path, date: day, size: fileSize(path, fm)))
            } else if entry.hasPrefix(logFileName) || entry.hasSuffix(".log") {
                let modified = (try? fm.attributesOfItem(atPath: entryPath))?[.modificationDate] as? Date
                found.append(LogSession(id: entry, name: entry, path: entryPath, date: modified, size: fileSize(entryPath, fm)))
            }
        }

        return found.sorted {
            let lhs = $0.date ?? .distantPast
            let rhs = $1.date ?? .distantPast
            return lhs == rhs ? $0.name > $1.name : lhs > rhs
        }
    }

    private static func fileSize(_ path: String, _ fm: FileManager) -> Int64 {
        ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
