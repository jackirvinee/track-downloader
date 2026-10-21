import Foundation
import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "TrackDownloaderAppearancePreference"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    init(storedValue: String) {
        self = Self(rawValue: storedValue) ?? .system
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(storedValue: defaults.string(forKey: storageKey) ?? system.rawValue)
    }

    func persist(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
