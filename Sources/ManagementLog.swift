import Foundation

// MARK: - Log Levels
enum LogLevel: Int {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    var stringValue: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}

// MARK: - Management Log
/// Day-nested, size-rolled log file shared by every subcommand.
///
/// The tool is invoked by scripts and packages, far too often to justify a
/// directory per run, so the day directory is its session: lines go to
/// `logs/<yyyy-MM-dd>/manageusers.log` with `events.jsonl` beside them, one
/// JSON object per line, which is the layout every managed tool shares.
///
/// Lines are written as `[yyyy-MM-dd HH:mm:ss] LEVEL  message` in local time,
/// with the level padded to five characters. A file rolls at 10 MB to
/// `manageusers.log.1` through `manageusers.log.5` (newest is `.1`), and day
/// directories older than 30 days are removed the first time a process logs.
final class ManagementLog: @unchecked Sendable {
    static let defaultDirectory = "/Library/Managed Users/logs"
    static let fileName = "manageusers.log"
    static let legacyDirectory = "/Library/Management/Logs"
    static let legacyFileName = "ManageUsers.log"
    static let maxSize: UInt64 = 10_485_760
    static let generations = 5
    static let eventsFileName = "events.jsonl"
    static let retentionDays = 30

    static let shared = ManagementLog(directory: ManagementLog.defaultDirectory)

    let directory: String
    let legacyDirectory: String
    /// The day directory this process is currently writing into, and the log in
    /// it. Re-resolved per record, so a process still running at midnight rolls
    /// onto the new day rather than the one it started in.
    private(set) var path: String
    var echoToConsole = true

    private let lock = NSLock()
    private var preparedDay: String?
    private var pruned = false
    /// Separates this process's records from another's in a file they share.
    private let invocation = UUID().uuidString

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(directory: String, legacyDirectory: String = ManagementLog.legacyDirectory) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        self.path = ManagementLog.path(in: directory, on: Date())
    }

    /// The log a record written at `date` belongs in.
    static func path(in directory: String, on date: Date) -> String {
        return (directory as NSString)
            .appendingPathComponent(dayFormatter.string(from: date))
            .appending("/" + fileName)
    }

    nonisolated(unsafe) static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    nonisolated(unsafe) static let eventFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Builds one log line in the shared convention format.
    static func formatLine(level: LogLevel, message: String, date: Date = Date()) -> String {
        let timestamp = timestampFormatter.string(from: date)
        let levelString = level.stringValue.padding(toLength: 5, withPad: " ", startingAt: 0)
        return "[\(timestamp)] \(levelString) \(message)"
    }

    func debug(_ message: String) { write(.debug, message) }
    func info(_ message: String) { write(.info, message) }
    func warning(_ message: String) { write(.warning, message) }
    func error(_ message: String) { write(.error, message) }

    func write(_ level: LogLevel, _ message: String) {
        let now = Date()
        let line = ManagementLog.formatLine(level: level, message: message, date: now)

        lock.lock()
        defer { lock.unlock() }

        prepareIfNeeded(for: now)
        rotateIfNeeded()
        append(line + "\n")
        appendEvent(level: level, message: message, date: now)

        if echoToConsole {
            print(line)
        }
    }

    // MARK: - Private

    private func prepareIfNeeded(for date: Date) {
        let day = ManagementLog.dayFormatter.string(from: date)
        path = ManagementLog.path(in: directory, on: date)
        guard preparedDay != day else { return }
        preparedDay = day

        let fm = FileManager.default
        let dayDirectory = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dayDirectory) {
            try? fm.createDirectory(
                atPath: dayDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        }

        migrateLegacyLogs()
        pruneIfNeeded(now: date)

        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
    }

    /// Removes day directories past the retention window, once per process.
    /// The flat log this layout replaced, and its rolled generations, age out
    /// by the same rule.
    private func pruneIfNeeded(now: Date) {
        guard !pruned else { return }
        pruned = true

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory),
              let cutoff = Calendar.current.date(byAdding: .day, value: -ManagementLog.retentionDays, to: now) else { return }

        for entry in entries {
            let full = (directory as NSString).appendingPathComponent(entry)
            if let day = ManagementLog.dayFormatter.date(from: entry), day < cutoff {
                try? fm.removeItem(atPath: full)
                continue
            }
            guard entry.hasPrefix(ManagementLog.fileName),
                  let attributes = try? fm.attributesOfItem(atPath: full),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date, modified < cutoff else { continue }
            try? fm.removeItem(atPath: full)
        }
    }

    /// The same record, structured, in the day directory's event stream.
    private func appendEvent(level: LogLevel, message: String, date: Date) {
        let record: [String: String] = [
            "timestamp": ManagementLog.eventFormatter.string(from: date),
            "level": level.stringValue,
            "event_type": level == .error ? "error" : "message",
            "tool": "manageusers",
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "invocation_id": invocation,
            "message": message
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        let events = (path as NSString).deletingLastPathComponent + "/" + ManagementLog.eventsFileName
        let fm = FileManager.default
        if !fm.fileExists(atPath: events) {
            fm.createFile(atPath: events, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        guard let payload = (line + "\n").data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: events) else { return }
        handle.seekToEndOfFile()
        handle.write(payload)
        handle.closeFile()
    }

    /// Best-effort move of the previous log location into the new directory.
    private func migrateLegacyLogs() {
        let fm = FileManager.default
        guard legacyDirectory != directory,
              let entries = try? fm.contentsOfDirectory(atPath: legacyDirectory) else { return }

        for entry in entries where entry.hasPrefix(ManagementLog.legacyFileName) {
            let source = (legacyDirectory as NSString).appendingPathComponent(entry)
            let targetName: String
            if entry == ManagementLog.legacyFileName {
                targetName = ManagementLog.fileName
            } else {
                targetName = ManagementLog.fileName + entry.dropFirst(ManagementLog.legacyFileName.count)
            }
            // The old logs land at the root, not in a day directory: they cover
            // whatever days they cover, and the age sweep removes them in time.
            let target = (directory as NSString).appendingPathComponent(targetName)
            guard !fm.fileExists(atPath: target) else { continue }
            try? fm.moveItem(atPath: source, toPath: target)
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let size = attributes[.size] as? UInt64,
              size >= ManagementLog.maxSize else { return }

        let oldest = "\(path).\(ManagementLog.generations)"
        if fm.fileExists(atPath: oldest) {
            try? fm.removeItem(atPath: oldest)
        }

        if ManagementLog.generations > 1 {
            for index in stride(from: ManagementLog.generations - 1, through: 1, by: -1) {
                let from = "\(path).\(index)"
                let to = "\(path).\(index + 1)"
                if fm.fileExists(atPath: from) {
                    try? fm.moveItem(atPath: from, toPath: to)
                }
            }
        }

        try? fm.moveItem(atPath: path, toPath: "\(path).1")
        fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
    }

    private func append(_ text: String) {
        guard let data = text.data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
}
