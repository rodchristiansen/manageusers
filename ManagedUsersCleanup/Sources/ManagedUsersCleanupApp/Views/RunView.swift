//
//  RunView.swift
//  Managed Users Cleanup
//
//  Run tab: simulate a cleanup or run it live, with the accounts confirmed in a
//  sheet first, and watch the output.
//

import SwiftUI
import ManagedUsersCleanupXPC

struct RunView: View {
    @Environment(XPCClient.self) private var xpcClient
    @State private var showDebug = false
    /// Simulate is the default; a live cleanup always starts with one.
    @State private var mode: RunMode = .simulate
    /// A live cleanup is waiting for its simulation to finish.
    @State private var awaitingConfirmation = false
    @State private var confirmation: [PlannedDeletion]?

    private var helperNeeded: Bool { true }
    private var helperAvailable: Bool { xpcClient.helperStatus == .available }

    var body: some View {
        VStack(spacing: 0) {
            modeSelector
                .padding([.horizontal, .top])

            runControlBar
                .padding()

            resultBanner

            Divider()

            ConsoleView(outputLines: showDebug ? xpcClient.outputLines : xpcClient.outputLines.filter { $0.level != .debug })
                .padding()
        }
        .onChange(of: xpcClient.isRunning) { _, running in
            guard !running, awaitingConfirmation else { return }
            awaitingConfirmation = false
            guard xpcClient.lastExitCode == 0, let plan = xpcClient.plan else { return }
            if plan.isEmpty {
                xpcClient.outputLines.append(.init(text: "INFO: No account matches the cleanup rules; nothing to delete.", level: .info))
            } else {
                confirmation = plan
            }
        }
        .sheet(item: Binding(
            get: { confirmation.map(ConfirmationList.init) },
            set: { if $0 == nil { confirmation = nil } }
        )) { list in
            ConfirmDeletionSheet(accounts: list.accounts) {
                confirmation = nil
                xpcClient.run(mode: .live, confirmed: list.accounts.map(\.name))
            } onCancel: {
                confirmation = nil
                xpcClient.outputLines.append(.init(text: "INFO: Live cleanup cancelled; no account was deleted.", level: .info))
            }
        }
    }

    private func start() {
        switch mode {
        case .simulate:
            xpcClient.run(mode: .simulate)
        case .live:
            // Always simulate first, so the user confirms the exact list.
            awaitingConfirmation = true
            xpcClient.run(mode: .simulate)
        }
    }

    // MARK: - Mode Selector

    @ViewBuilder
    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Run", selection: $mode) {
                ForEach(RunMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(xpcClient.isRunning)

            Text(mode.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Run Control Bar

    @ViewBuilder
    private var runControlBar: some View {
        HStack(spacing: 12) {
            if xpcClient.isRunning {
                stopButton
            } else {
                runButton
            }

            if xpcClient.isRunning {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Running...")
                        .foregroundStyle(.secondary)
                    if let caption = xpcClient.latestProgressLine {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()

            statusIndicator

            Toggle("Debug", isOn: $showDebug)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Show or hide DEBUG lines")

            if !xpcClient.outputLines.isEmpty && !xpcClient.isRunning {
                clearButton
            }
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var runButton: some View {
        let disabled = helperNeeded && !helperAvailable
        if #available(macOS 26, *) {
            Button {
                start()
            } label: {
                Label(mode == .live ? "Review and Delete" : "Run Simulation", systemImage: mode == .live ? "trash" : "play.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(mode == .live ? .red : .green)
            .controlSize(.large)
            .disabled(disabled)
        } else {
            Button {
                start()
            } label: {
                Label(mode == .live ? "Review and Delete" : "Run Simulation", systemImage: mode == .live ? "trash" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(disabled)
        }
    }

    @ViewBuilder
    private var stopButton: some View {
        if #available(macOS 26, *) {
            Button(role: .destructive) {
                xpcClient.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.large)
        } else {
            Button(role: .destructive) {
                xpcClient.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var clearButton: some View {
        if #available(macOS 26, *) {
            Button("Clear") { clearOutput() }
                .buttonStyle(.glass)
                .controlSize(.small)
        } else {
            Button("Clear") { clearOutput() }
                .controlSize(.small)
        }
    }

    private func clearOutput() {
        xpcClient.outputLines.removeAll()
        xpcClient.lastExitCode = nil
    }

    // MARK: - Status

    @ViewBuilder
    private var statusIndicator: some View {
        if let exitCode = xpcClient.lastExitCode {
            if exitCode == 0 && xpcClient.errorCount == 0 {
                Label("Completed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if exitCode == 0 {
                // Matches the banner: a run that logged errors is not shown as clean.
                Label("Completed with errors", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else {
                Label("Failed (exit \(exitCode))", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }

        if helperNeeded && !helperAvailable && !xpcClient.isRunning {
            Label("Helper not available", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var resultBanner: some View {
        if let exitCode = xpcClient.lastExitCode, !xpcClient.isRunning {
            let errors = xpcClient.errorCount
            let success = exitCode == 0
            HStack(spacing: 8) {
                Image(systemName: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                Text(success
                     ? (errors == 0 ? "Completed successfully" : "Completed with \(errors) error\(errors == 1 ? "" : "s")")
                     : "Failed with exit code \(exitCode), \(errors) error\(errors == 1 ? "" : "s")")
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(success && errors == 0 ? .green : .red)
            .padding(10)
            .background((success && errors == 0 ? Color.green : Color.red).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

/// The accounts awaiting confirmation, as a sheet item.
private struct ConfirmationList: Identifiable {
    let accounts: [PlannedDeletion]
    var id: String { accounts.map(\.name).joined(separator: ",") }
}

/// Lists exactly what a live cleanup will delete. Cancel is the default.
struct ConfirmDeletionSheet: View {
    let accounts: [PlannedDeletion]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Delete \(accounts.count) account\(accounts.count == 1 ? "" : "s")?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.red)
            Text("Each account, its home folder and its data are removed. This cannot be undone. Only the accounts listed here are deleted, and only if the rules still allow it when the cleanup runs.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(accounts) { account in
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).font(.body.monospaced())
                    Text(account.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 160)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Delete \(accounts.count) Account\(accounts.count == 1 ? "" : "s")", role: .destructive, action: onConfirm)
                    .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
