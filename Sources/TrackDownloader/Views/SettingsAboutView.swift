import SwiftUI
import TrackDownloaderCore

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

            SoundCloudSignInSection()

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

/// Lets SoundCloud downloads borrow the browser's login. Off unless chosen.
struct SoundCloudSignInSection: View {
    @AppStorage(SoundCloudSignInPreference.browserKey)
    private var browserRawValue = SoundCloudSignInPreference.offValue
    @AppStorage(SoundCloudSignInPreference.profileKey)
    private var profile = ""

    private var browser: SoundCloudSignIn.Browser? {
        SoundCloudSignIn.Browser(rawValue: browserRawValue)
    }

    var body: some View {
        Section("SoundCloud Sign-In") {
            Picker("Use login from", selection: $browserRawValue) {
                Text("Don't sign in").tag(SoundCloudSignInPreference.offValue)
                ForEach(SoundCloudSignIn.Browser.allCases) { browser in
                    Text(browser.title).tag(browser.rawValue)
                }
            }
            .accessibilityHint("Choose a browser where you're signed in to SoundCloud, so downloads can get originals and Go+ quality.")

            if let browser, browser.supportsProfiles {
                TextField("Profile", text: $profile, prompt: Text("Default"))
                    .accessibilityHint("The browser profile folder name, such as Default or Profile 1. Leave empty for the default profile.")
                if !SoundCloudSignIn.isPassableProfile(profile) {
                    Text("Profile names can't contain : or +. SoundCloud downloads will stay signed out.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: String {
        switch browser {
        case nil:
            "Signed out, SoundCloud gives 160 kbps AAC at best. Signing in unlocks an artist's original file when they allow downloads, and Go+ 256 kbps when it isn't DRM-protected."
        case .safari?:
            "Read from Safari only when a SoundCloud download runs. Track Downloader needs Full Disk Access to read Safari's login. Nothing is saved, and other sites never use it."
        case .some:
            "Read from the browser only when a SoundCloud download runs. macOS asks once for Keychain access to the browser's Safe Storage. Nothing is saved, and other sites never use it."
        }
    }
}
