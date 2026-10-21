import AppKit
import SwiftUI
import TrackDownloaderChromeCompanion

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct TrackDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updateStore: UpdateStore
    @StateObject private var chromeCompanionDownloadStore: DownloadStore
    @StateObject private var chromeCompanionPreflightStore: SourcePreflightStore
    @StateObject private var chromeQueueStore: ChromeQueueStore
    @State private var isSettingsSheetPresented = false
    @AppStorage(AppearancePreference.storageKey)
    private var appearanceRawValue = AppearancePreference.system.rawValue

    init() {
        #if DEBUG
        if TrackDownloaderFixture.isActive {
            let status = TrackDownloaderFixture.updateStatus
            _updateStore = StateObject(wrappedValue: UpdateStore.fixture(status: status ?? .idle))
        } else {
            _updateStore = StateObject(wrappedValue: UpdateStore.live())
        }
        #else
        _updateStore = StateObject(wrappedValue: UpdateStore.live())
        #endif

        let downloadStore = DownloadStore()
        let preflightStore = SourcePreflightStore()
        _chromeCompanionDownloadStore = StateObject(wrappedValue: downloadStore)
        _chromeCompanionPreflightStore = StateObject(wrappedValue: preflightStore)
        _chromeQueueStore = StateObject(wrappedValue: ChromeQueueStore())
    }

    var body: some Scene {
        WindowGroup("Track Downloader") {
            mainWindowContent
                .preferredColorScheme(effectiveColorScheme)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    chromeQueueStore.reload()
                }
        }
        .defaultSize(width: 1280, height: 760)
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { isSettingsSheetPresented = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        Settings {
            SettingsAboutView(
                updateStore: updateStore,
                appearanceRawValue: $appearanceRawValue
            )
            .preferredColorScheme(effectiveColorScheme)
        }
    }

    @ViewBuilder
    private var mainWindowContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .available(let release) = updateStore.status {
                UpdateNoticeView(release: release, dismiss: updateStore.dismissAvailableUpdate)
            }
            #if DEBUG
            let fixtureAppearance = TrackDownloaderFixture.appearanceConfiguration
            let expandFailureDetails = TrackDownloaderFixture.expandFailureDetails
            let fixtureStartsFocused = TrackDownloaderFixture.startsFocused
            #endif
            Group {
            #if DEBUG
                if TrackDownloaderFixture.showsSettingsAbout {
                    SettingsAboutView(
                        updateStore: updateStore,
                        appearanceRawValue: $appearanceRawValue
                    )
                } else {
                    let contentStore = TrackDownloaderFixture.storeFromEnvironment() ?? chromeCompanionDownloadStore
                    ContentView(
                        store: contentStore,
                        preflightStore: TrackDownloaderFixture.preflightStoreFromEnvironment() ?? chromeCompanionPreflightStore,
                        chromeQueueStore: chromeQueueStore,
                        failureDetailsInitiallyExpanded: expandFailureDetails,
                        linkFieldInitiallyFocused: fixtureStartsFocused,
                        presentSettings: { isSettingsSheetPresented = true }
                    )
                }
            #else
            ContentView(
                store: chromeCompanionDownloadStore,
                preflightStore: chromeCompanionPreflightStore,
                chromeQueueStore: chromeQueueStore,
                presentSettings: { isSettingsSheetPresented = true }
            )
            #endif
            }
            .sheet(isPresented: $isSettingsSheetPresented) {
                SettingsAboutView(
                    updateStore: updateStore,
                    appearanceRawValue: $appearanceRawValue
                )
                    .frame(minWidth: 360)
                    .preferredColorScheme(effectiveColorScheme)
            }
            #if DEBUG
            .environment(\.dynamicTypeSize, fixtureAppearance.dynamicTypeSize ?? .large)
            .environment(\.trackDownloaderFixtureReduceMotion, fixtureAppearance.reduceMotion)
            .transaction { transaction in
                if fixtureAppearance.reduceMotion {
                    transaction.disablesAnimations = true
                }
            }
            #else
            #endif
        }
        .task {
            await Task.yield()
            updateStore.beginAutomaticCheck()
        }
    }

    private var savedColorScheme: ColorScheme? {
        AppearancePreference(storedValue: appearanceRawValue).colorScheme
    }

    private var effectiveColorScheme: ColorScheme? {
        #if DEBUG
        TrackDownloaderFixture.appearanceConfiguration.colorScheme ?? savedColorScheme
        #else
        savedColorScheme
        #endif
    }
}
