import TrackDownloaderCore
import XCTest
@testable import TrackDownloader

final class SourcePanePresentationTests: XCTestCase {
    func testDownloadStateTakesPrecedenceOverPreflightState() {
        let progress = DownloadProgress(stage: .downloading, fractionCompleted: 0.42, detail: nil)
        XCTAssertEqual(
            SourcePaneStatusPresentation(downloadState: .running(progress), preflightState: .checking),
            .init(text: "Download in progress", systemImage: "arrow.down.circle", role: .inProgress, accessibilityLabel: "Source status: Download in progress")
        )
    }

    func testIdlePreflightStatesAreTruthful() {
        XCTAssertEqual(SourcePaneStatusPresentation(downloadState: .idle, preflightState: .idle).text, "Ready")
        XCTAssertEqual(SourcePaneStatusPresentation(downloadState: .idle, preflightState: .checking).text, "Checking source")
        XCTAssertEqual(SourcePaneStatusPresentation(downloadState: .idle, preflightState: .invalidLink("bad")).role, .failure)
    }

    func testRecentHistoryIsNewestFirstAndBounded() {
        let tracks = (0..<5).map { index in
            DownloadedTrack(
                fileURL: URL(fileURLWithPath: "/tmp/Track \(index).m4a"),
                metadata: TrackMetadata(title: "Track \(index)"),
                savedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertEqual(SourceHistoryItem.recent(from: tracks, limit: 3).map(\.title), ["Track 4", "Track 3", "Track 2"])
        XCTAssertEqual(SourceHistoryItem.recent(from: tracks, limit: 0), [])
    }
}
