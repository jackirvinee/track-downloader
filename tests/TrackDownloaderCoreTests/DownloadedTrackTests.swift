import TrackDownloaderCore
import Foundation
import XCTest

final class DownloadedTrackTests: XCTestCase {
    func testMissingMetadataUsesFilenameAndFileExtension() {
        let fileURL = URL(fileURLWithPath: "/tmp/Unknown Artist - Night Drive.flac")
        let savedAt = Date(timeIntervalSince1970: 1_721_000_000)

        let track = DownloadedTrack(
            fileURL: fileURL,
            metadata: nil,
            savedAt: savedAt
        )

        XCTAssertEqual(track.title, "Unknown Artist - Night Drive")
        XCTAssertNil(track.artist)
        XCTAssertNil(track.album)
        XCTAssertNil(track.genre)
        XCTAssertEqual(track.format, "FLAC")
        XCTAssertEqual(track.savedAt, savedAt)
        XCTAssertEqual(track.libraryID, fileURL.standardizedFileURL.path)
    }

    func testSidecarMetadataSuppliesOnlyEvidenceBackedTitleAndArtist() {
        let fileURL = URL(fileURLWithPath: "/tmp/source/song.m4a")

        let track = DownloadedTrack(
            fileURL: fileURL,
            metadata: TrackMetadata(
                title: "Night Drive",
                artist: "Example Artist",
                album: "After Hours",
                genre: "Electronic"
            ),
            savedAt: .distantPast,
            fileSizeBytes: 42_000_000,
            relativeDirectory: "soundcloud/Example Artist"
        )

        XCTAssertEqual(track.title, "Night Drive")
        XCTAssertEqual(track.artist, "Example Artist")
        XCTAssertEqual(track.album, "After Hours")
        XCTAssertEqual(track.genre, "Electronic")
        XCTAssertEqual(track.format, "M4A")
        XCTAssertEqual(track.fileSizeBytes, 42_000_000)
        XCTAssertEqual(track.relativeDirectory, "soundcloud/Example Artist")
    }
}
