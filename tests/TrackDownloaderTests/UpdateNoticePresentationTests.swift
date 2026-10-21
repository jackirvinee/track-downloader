import Foundation
import XCTest
@testable import TrackDownloader

final class UpdateNoticePresentationTests: XCTestCase {
    func testPresentationPreservesValidatedReleaseDetailsAndExactPageURL() {
        let release = UpdateRelease(
            version: StableVersion(releaseTag: "v1.1.0")!,
            notes: "Safer downloads and clearer errors.",
            pageURL: URL(string: "https://github.com/jackirvinee/track-downloader/releases/tag/v1.1.0")!
        )

        let presentation = UpdateNoticePresentation(release: release)

        XCTAssertEqual(presentation.title, "Update available")
        XCTAssertEqual(presentation.versionText, "Version 1.1.0")
        XCTAssertEqual(presentation.notes, "Safer downloads and clearer errors.")
        XCTAssertEqual(presentation.downloadTitle, "Download from GitHub")
        XCTAssertEqual(
            presentation.downloadURL.absoluteString,
            "https://github.com/jackirvinee/track-downloader/releases/tag/v1.1.0"
        )
    }
}
