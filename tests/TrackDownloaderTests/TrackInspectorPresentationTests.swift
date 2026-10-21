import TrackDownloaderCore
import XCTest
@testable import TrackDownloader

final class TrackInspectorPresentationTests: XCTestCase {
    func testKnownLocalFactsArePresentedWithoutInventingAudioFacts() {
        let track = DownloadedTrack(
            fileURL: URL(fileURLWithPath: "/tmp/library/Artist - Track.opus"),
            metadata: TrackMetadata(title: "Track", artist: "Artist", album: "Album", genre: "House"),
            savedAt: Date(timeIntervalSince1970: 1_723_000_000),
            fileSizeBytes: 12_500_000,
            relativeDirectory: "SoundCloud / Artist"
        )
        let presentation = TrackInspectorPresentation(track: track)

        XCTAssertEqual(presentation.title, "Track")
        XCTAssertEqual(presentation.artist, "Artist")
        XCTAssertEqual(presentation.value(for: .path), "/tmp/library/Artist - Track.opus")
        XCTAssertEqual(presentation.value(for: .format), "OPUS")
        XCTAssertEqual(presentation.value(for: .album), "Album")
        XCTAssertEqual(presentation.value(for: .genre), "House")
        XCTAssertEqual(presentation.value(for: .source), "SoundCloud / Artist")
        for field in [TrackInspectorField.quality, .duration, .codec, .bitrate, .sampleRate] {
            XCTAssertEqual(presentation.value(for: field), "—")
        }
    }

    func testMissingOptionalFactsUseEmDash() {
        let track = DownloadedTrack(
            fileURL: URL(fileURLWithPath: "/tmp/library/Recorder.wav"),
            metadata: nil,
            savedAt: Date(timeIntervalSince1970: 1_723_000_000)
        )
        let presentation = TrackInspectorPresentation(track: track)

        XCTAssertEqual(presentation.title, "Recorder")
        XCTAssertEqual(presentation.artist, "—")
        XCTAssertEqual(presentation.value(for: .fileSize), "—")
        XCTAssertEqual(presentation.value(for: .album), "—")
        XCTAssertEqual(presentation.value(for: .genre), "—")
        XCTAssertEqual(presentation.value(for: .source), "—")
    }
}
