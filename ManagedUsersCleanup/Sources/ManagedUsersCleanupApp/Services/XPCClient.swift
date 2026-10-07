//
//  XPCClient.swift
//  Managed Users Cleanup
//
//  Manages the NSXPCConnection to the privileged helper daemon.
//  Streams manageusers' output back to the window and handles preference writes.
//

import Foundation
import ManagedUsersCleanupXPC

@Observable
@MainActor
final class XPCClient: NSObject {
    var outputLines: [OutputLine] = []
    var isRunning = false
    var lastExitCode: Int32?
    var helperStatus: HelperStatus = .unknown
    var connectionError: String?
    /// The accounts the last simulation would delete; nil until one finishes.
    var plan: [PlannedDeletion]?
    /// The mode of the run in progress or last finished.
    var lastMode: RunMode?

    private var connection: NSXPCConnection?

    struct OutputLine: Identifiable {
        let id = UUID()
        let text: String
        let level: LineLevel
    }

    enum HelperStatus: String {
        case unknown = "Unknown"
        case available = "Available"
        case unavailable = "Unavailable"
    }

    var errorCount: Int {
        outputLines.filter { $0.level == .error }.count
    }

    /// The newest line worth showing as the run's progress caption.
    var latestProgressLine: String? {
        outputLines.last { $0.level == .info || $0.level == .header }?.text
    }

    // MARK: - Connection Management

    func connect() {
        guard connection == nil else { return }

        let conn = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = .cleanupHelperInterface()
        conn.exportedInterface = NSXPCInterface(with: HelperXPCClientProtocol.self)
        conn.exportedObject = self

        conn.invalidationHandler = makeInvalidationHandler()
        conn.interruptionHandler = makeInterruptionHandler()

        conn.resume()
        connection = conn
        connectionError = nil

        // Ping the helper: the package installs it as a LaunchDaemon, so a reply
        // is the only check needed.
        helperProxy { [weak self] proxy in
            proxy.getHelperVersion { _ in
                Task { @MainActor [weak self] in
                    self?.helperStatus = .available
                    self?.connectionError = nil
                }
            }
        }
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Runs

    /// Starts a run. A live run takes the accounts the user confirmed from
    /// the last simulation; the tool deletes no others.
    func run(mode: RunMode, confirmed accounts: [String] = []) {
        guard !isRunning else { return }

        outputLines.removeAll()
        lastExitCode = nil
        connectionError = nil
        lastMode = mode
        if mode == .simulate { plan = nil }

        isRunning = true
        connect()
        helperProxy { proxy in
            proxy.run(mode: mode.rawValue, accounts: accounts)
        }
    }

    func stop() {
        helperProxy { proxy in
            proxy.stop()
        }
        isRunning = false
        lastExitCode = nil
        outputLines.append(OutputLine(text: "WARN: Run stopped by user.", level: .warning))
    }

    // MARK: - Preference Management

    func setStringPreference(key: UsersPreferenceKey, value: String) async -> Bool {
        await callHelper { proxy, reply in proxy.setStringPreference(key: key.rawValue, value: value, withReply: reply) }
    }

    func setBoolPreference(key: UsersPreferenceKey, value: Bool) async -> Bool {
        await callHelper { proxy, reply in proxy.setBoolPreference(key: key.rawValue, value: value, withReply: reply) }
    }

    func setIntPreference(key: UsersPreferenceKey, value: Int) async -> Bool {
        await callHelper { proxy, reply in proxy.setIntPreference(key: key.rawValue, value: value, withReply: reply) }
    }

    func setArrayPreference(key: UsersPreferenceKey, value: [String]) async -> Bool {
        await callHelper { proxy, reply in proxy.setArrayPreference(key: key.rawValue, value: value, withReply: reply) }
    }

    func removePreference(key: UsersPreferenceKey) async -> Bool {
        await callHelper { proxy, reply in proxy.removePreference(key: key.rawValue, withReply: reply) }
    }

    // MARK: - Private

    /// Calls the helper and waits for its reply; a refused or broken connection
    /// counts as a failed write rather than leaving the caller waiting.
    private func callHelper(
        _ body: @escaping @Sendable (HelperXPCProtocol, @escaping @Sendable (Bool) -> Void) -> Void
    ) async -> Bool {
        connect()
        guard let conn = connection else { return false }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in once.resume(false) }) as? HelperXPCProtocol else {
                once.resume(false)
                return
            }
            body(proxy) { ok in once.resume(ok) }
        }
    }

    /// Creates XPC callbacks in a nonisolated context so they don't inherit
    /// @MainActor isolation and crash when called on the XPC dispatch queue.
    private nonisolated func makeInvalidationHandler() -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                self?.connection = nil
                self?.helperStatus = .unavailable
                self?.reportConnectionFailure("Connection to helper was invalidated")
            }
        }
    }

    private nonisolated func makeInterruptionHandler() -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                self?.reportConnectionFailure("Connection to helper was interrupted")
            }
        }
    }

    private nonisolated func makeErrorHandler() -> @Sendable (any Error) -> Void {
        { [weak self] error in
            Task { @MainActor [weak self] in
                self?.reportConnectionFailure(error.localizedDescription)
            }
        }
    }

    /// A failed connection during a run must show up in the run output, in red.
    private func reportConnectionFailure(_ message: String) {
        connectionError = message
        if isRunning {
            outputLines.append(OutputLine(text: "ERROR: \(message). The helper refused the connection or is not running; see the system log for com.github.manageusers.helper.", level: .error))
            isRunning = false
        }
    }

    private func helperProxy(block: @escaping (HelperXPCProtocol) -> Void) {
        guard let conn = connection else {
            connectionError = "No connection to helper"
            return
        }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler(makeErrorHandler()) as? HelperXPCProtocol else {
            connectionError = "Failed to get helper proxy"
            return
        }
        block(proxy)
    }
}

/// Resumes a continuation exactly once, whichever of the reply or the
/// connection error arrives first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

// MARK: - HelperXPCClientProtocol

extension XPCClient: HelperXPCClientProtocol {

    nonisolated func didReceiveOutput(_ line: String) {
        // The plan line is data for the confirmation sheet, not console output.
        if let planned = PlannedDeletion.parsePlanLine(line) {
            Task { @MainActor in
                plan = planned
                outputLines.append(OutputLine(
                    text: "INFO: \(planned.count) account\(planned.count == 1 ? "" : "s") would be deleted.",
                    level: .info))
            }
            return
        }
        let level = LineLevel.classify(line)
        Task { @MainActor in
            outputLines.append(OutputLine(text: line, level: level))
        }
    }

    nonisolated func runDidComplete(success: Bool, exitCode: Int32) {
        Task { @MainActor in
            isRunning = false
            lastExitCode = exitCode
        }
    }

    nonisolated func didEncounterError(_ message: String) {
        Task { @MainActor in
            connectionError = message
            outputLines.append(OutputLine(text: "ERROR: \(message)", level: .error))
        }
    }
}
