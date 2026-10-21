import SwiftUI

struct SettingsAboutView: View {
    @ObservedObject var updateStore: UpdateStore
    @Binding var appearanceRawValue: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearanceRawValue) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.title).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Appearance")
                .accessibilityHint("Choose whether Track Downloader follows the system, uses light appearance, or uses dark appearance.")

                Text("System follows your Mac appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About Track Downloader") {
                Text("Track Downloader")
                    .font(.headline)
                Text("Created by Jack Irvine")
                Text("Copyright 2026 Jack Irvine")
                Text("MIT License")
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Button("Check for Updates") {
                        updateStore.beginManualCheck()
                    }
                    .disabled(updateStore.status == .checking)
                    .accessibilityHint("Checks GitHub for a newer stable Track Downloader release.")

                    Text(updateStore.installedVersionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                updateStatus
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .padding()
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updateStore.status {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView("Checking for updates")
        case .upToDate:
            Text("You're up to date")
                .foregroundStyle(.secondary)
        case .available(let release):
            let presentation = UpdateNoticePresentation(release: release)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.versionText)
                    .font(.headline)
                Text(presentation.notes)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                Button(presentation.downloadTitle) {
                    openURL(presentation.downloadURL)
                }
                .accessibilityHint("Opens this release on GitHub in your default browser.")
            }
        case .manualFailure(let message):
            Text(message)
                .foregroundStyle(.secondary)
        }
    }
}
