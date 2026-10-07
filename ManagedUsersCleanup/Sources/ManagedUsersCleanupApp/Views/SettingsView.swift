//
//  SettingsView.swift
//  Managed Users Cleanup
//
//  Prefs tab: centred app header, then manageusers' preferences in two columns
//  of cards. Managed settings show their managed value, locked.
//

import SwiftUI
import ManagedUsersCleanupXPC

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(XPCClient.self) private var xpcClient

    private var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                appInfoHeader

                Divider()

                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 16) {
                        thresholdSection
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    VStack(spacing: 16) {
                        exclusionsSection
                        adminsSection
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }

                HStack {
                    Spacer()
                    saveStatusLabel
                }
                .padding(.top, 4)
            }
            .padding()
        }
        .onAppear {
            viewModel.configure(client: xpcClient)
            viewModel.load()
        }
    }

    // MARK: - App Info Header

    @ViewBuilder
    private var appInfoHeader: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)

            Text("Managed Users Cleanup")
                .font(.largeTitle.bold())

            Text("Removes local accounts that have gone unused on shared Macs, under rules an administrator sets.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("Documentation", destination: URL(string: "https://github.com/rodchristiansen/manageusers#readme")!)
                    .font(.caption)
                Link("Report Issue", destination: URL(string: "https://github.com/rodchristiansen/manageusers/issues")!)
                    .font(.caption)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Auto-Save Status

    @ViewBuilder
    private var saveStatusLabel: some View {
        switch viewModel.saveStatus {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Saving").font(.callout).foregroundStyle(.secondary)
            }
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .transition(.opacity)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var thresholdSection: some View {
        card("Deletion threshold", systemImage: "calendar.badge.clock") {
            settingRow(.deletionDays, label: "Delete after") {
                numberField(value: $viewModel.deletionDays, range: 0...3650, step: 1, unit: "days, 0 for the area default")
            }
            settingRow(.deletionStrategy, label: "Counted from") {
                Picker("", selection: $viewModel.strategy) {
                    ForEach(StrategyChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260, alignment: .leading)
            }
            Text("With creation and last login, an account goes only when both are older than the threshold. An account that never logged in counts as idle.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var exclusionsSection: some View {
        card("Exclusions", systemImage: "person.crop.circle.badge.checkmark") {
            settingRow(.additionalExclusions, label: "Never delete") {
                TextField("support, kiosk", text: $viewModel.additionalExclusionsText)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Added to the built-in list and the exclusions in the sessions file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var adminsSection: some View {
        card("Administrators", systemImage: "person.badge.shield.checkmark") {
            settingRow(.deleteAdmins) {
                Toggle("Allow admin accounts to be deleted", isOn: $viewModel.deleteAdmins)
            }
            settingRow(.deletableAdmins, label: "Admins that may be deleted anyway") {
                TextField("oldadmin", text: $viewModel.deletableAdminsText)
                    .textFieldStyle(.roundedBorder)
            }
            Text("The last admin owner of the startup disk is never deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Building Blocks

    @ViewBuilder
    private func card<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }

    @ViewBuilder
    private func numberField(value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Managed Setting Row

    @ViewBuilder
    private func settingRow<Content: View>(
        _ key: UsersPreferenceKey,
        label: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let managed = viewModel.isManaged(key)
        VStack(alignment: .leading, spacing: 2) {
            if let label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
                .disabled(managed)
            if managed {
                Label("Managed", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
