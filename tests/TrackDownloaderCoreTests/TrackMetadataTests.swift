import Foundation
import XCTest
@testable import TrackDownloaderCore

final class TrackMetadataTests: XCTestCase {
    func testDecodesTrackMetadataUsingExplicitArtistBeforeUploader() throws {
        let data = Data("""
        {
          "title": "Night Drive",
          "artist": "Primary Artist",
          "uploader": "Fallback Uploader",
          "album": "After Hours",
          "genre": "Electronic",
          "thumbnail": "https://images.example.com/cover.jpg"
        }
        """.utf8)

        let metadata = try XCTUnwrap(TrackMetadata.decode(from: data))

        XCTAssertEqual(metadata.title, "Night Drive")
        XCTAssertEqual(metadata.artist, "Primary Artist")
        XCTAssertEqual(metadata.album, "After Hours")
        XCTAssertEqual(metadata.genre, "Electronic")
        XCTAssertEqual(metadata.artworkURL, URL(string: "https://images.example.com/cover.jpg"))
    }

    func testDecodesUploaderWhenExplicitArtistIsAbsent() throws {
        let data = Data("""
        { "title": "Night Drive", "uploader": "Fallback Uploader" }
        """.utf8)

        let metadata = try XCTUnwrap(TrackMetadata.decode(from: data))

        XCTAssertEqual(metadata.artist, "Fallback Uploader")
        XCTAssertNil(metadata.album)
        XCTAssertNil(metadata.genre)
        XCTAssertNil(metadata.artworkURL)
    }

    func testRejectsMalformedOrUntitledSidecars() {
        XCTAssertNil(TrackMetadata.decode(from: Data("{not json}".utf8)))
        XCTAssertNil(TrackMetadata.decode(from: Data("{ \"uploader\": \"Artist\" }".utf8)))
    }
}
