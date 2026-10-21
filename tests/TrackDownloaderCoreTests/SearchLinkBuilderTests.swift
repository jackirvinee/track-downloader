import XCTest
@testable import TrackDownloaderCore

final class SearchLinkBuilderTests: XCTestCase {
    func testBuildsLegitimateHigherQualitySearches() throws {
        let links = SearchLinkBuilder.urls(for: "Artist Track")

        XCTAssertEqual(links.count, 4)
        XCTAssertTrue(links.contains { $0.host == "bandcamp.com" })
        XCTAssertTrue(links.contains { $0.host == "www.beatport.com" })
        XCTAssertTrue(links.contains { $0.host == "soundcloud.com" })
        XCTAssertTrue(links.contains {
            $0.host == "www.google.com" &&
            $0.absoluteString.contains("lossless")
        })
    }

    func testDerivesCleanSearchTermsFromDownloadedFilename() {
        let file = URL(fileURLWithPath: "/tmp/Artist - Track Name [abc123].opus")
        XCTAssertEqual(SearchLinkBuilder.terms(from: file), "Artist Track Name")
    }
}
