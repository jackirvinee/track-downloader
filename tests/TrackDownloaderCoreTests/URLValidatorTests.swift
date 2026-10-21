import XCTest
@testable import TrackDownloaderCore

final class URLValidatorTests: XCTestCase {
    func testAcceptsYouTubeAndSoundCloudLinks() throws {
        XCTAssertEqual(
            try URLValidator.normalize("  https://youtu.be/abc123  ").absoluteString,
            "https://youtu.be/abc123"
        )
        XCTAssertEqual(
            try URLValidator.normalize("https://soundcloud.com/artist/track").host,
            "soundcloud.com"
        )
    }

    func testRejectsUnsupportedAndMalformedLinks() {
        XCTAssertThrowsError(try URLValidator.normalize("not a link"))
        XCTAssertThrowsError(try URLValidator.normalize("https://example.com/track"))
        XCTAssertThrowsError(try URLValidator.normalize("http://soundcloud.com/artist/track"))
        XCTAssertThrowsError(try URLValidator.normalize("https://user:password@youtube.com/watch?v=abc"))
        XCTAssertThrowsError(try URLValidator.normalize("file:///tmp/audio.mp3"))
    }
}
