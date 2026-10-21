import Foundation
import TrackDownloaderCore

/// Remembers only which browser and profile hold the SoundCloud login, never the login itself.
enum SoundCloudSignInPreference {
    static let browserKey = "TrackDownloaderSoundCloudSignInBrowser"
    static let profileKey = "TrackDownloaderSoundCloudSignInProfile"
    static let offValue = "off"

    static func load(from defaults: UserDefaults = .standard) -> SoundCloudSignIn {
        SoundCloudSignIn(
            browser: defaults.string(forKey: browserKey).flatMap(SoundCloudSignIn.Browser.init(rawValue:)),
            profile: defaults.string(forKey: profileKey) ?? ""
        )
    }
}
