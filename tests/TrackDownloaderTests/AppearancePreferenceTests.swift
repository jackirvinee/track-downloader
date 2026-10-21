import SwiftUI
import XCTest
@testable import TrackDownloader

final class AppearancePreferenceTests: XCTestCase {
    func testChoicesAndColourSchemeMappingAreExact() {
        XCTAssertEqual(AppearancePreference.allCases, [.system, .light, .dark])
        XCTAssertEqual(AppearancePreference.system.title, "System")
        XCTAssertEqual(AppearancePreference.light.title, "Light")
        XCTAssertEqual(AppearancePreference.dark.title, "Dark")
        XCTAssertNil(AppearancePreference.system.colorScheme)
        XCTAssertEqual(AppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.colorScheme, .dark)
    }

    func testPersistenceRoundTripsAndUnknownValuesFallBackToSystem() {
        let suite = "AppearancePreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppearancePreference.load(from: defaults), .system)
        AppearancePreference.dark.persist(to: defaults)
        XCTAssertEqual(defaults.string(forKey: AppearancePreference.storageKey), "dark")
        XCTAssertEqual(AppearancePreference.load(from: defaults), .dark)

        defaults.set("future-value", forKey: AppearancePreference.storageKey)
        XCTAssertEqual(AppearancePreference.load(from: defaults), .system)
    }
}
