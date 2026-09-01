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
/// Flat, size-rolled log file shared by every subcommand.
///
/// Lines are written as `[yyyy-MM-dd HH:mm:ss] LEVEL  message` in local time,
/// with the level padded to five characters. The file rolls at 10 MB to
/// `manageusers.log.1` through `manageusers.log.5` (newest is `.1`) and is
/// never truncated on age.
final class ManagementLog: @unchecked Sendable {
    static let defaultDirectory = "/Library/Managed Users/logs"
    static let fileName = "manageusers.log"
    static let legacyDirectory = "/Library/Management/Logs"
    static let legacyFileName = "ManageUsers.log"
    static let maxSize: UInt64 = 10_485_760
    static let generations = 5

    static let shared = ManagementLog(directory: ManagementLog.defaultDirectory)

    let directory: String
    let legacyDirectory: String
    let path: String
    var echoToConsole = true

    private let lock = NSLock()
    private var ready = false

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
        self.path = (directory as NSString).appendingPathComponent(ManagementLog.fileName)
    }

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
        let line = ManagementLog.formatLine(level: level, message: message)

        lock.lock()
        defer { lock.unlock() }

        prepareIfNeeded()
        rotateIfNeeded()
        append(line + "\n")

        if echoToConsole {
            print(line)
        }
    }

    // MARK: - Private

    private func prepareIfNeeded() {
        guard !ready else { return }
        ready = true

        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try? fm.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        }

        if !fm.fileExists(atPath: path) {
            migrateLegacyLogs()
        }

        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
    }

    /// Best-effort move of the previous log location into the new directory.
    /// Only runs when the new log does not exist yet, so it happens once.
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
