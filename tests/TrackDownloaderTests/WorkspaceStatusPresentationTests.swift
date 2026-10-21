import TrackDownloaderCore
import XCTest
@testable import TrackDownloader

final class WorkspaceStatusPresentationTests: XCTestCase {
    func testStatusCombinesOutputStateAndLibraryCount() {
        let source = SourcePaneStatusPresentation(
            text: "Ready to download",
            systemImage: "checkmark.circle",
            role: .success,
            accessibilityLabel: "Source status: Ready to download"
        )
        let presentation = WorkspaceStatusPresentation(
            sourceStatus: source,
            outputDirectory: URL(fileURLWithPath: "/tmp/Track Downloader"),
            libraryCount: 3
        )

        XCTAssertEqual(presentation.stateText, "Ready to download")
        XCTAssertEqual(presentation.outputPath, "/tmp/Track Downloader")
        XCTAssertEqual(presentation.libraryText, "3 tracks")
        XCTAssertEqual(presentation.accessibilityLabel, "Ready to download. Output /tmp/Track Downloader. Library 3 tracks.")
    }

    func testSingularLibraryCount() {
        let source = SourcePaneStatusPresentation(downloadState: .idle, preflightState: .idle)
        XCTAssertEqual(
            WorkspaceStatusPresentation(sourceStatus: source, outputDirectory: URL(fileURLWithPath: "/tmp/out"), libraryCount: 1).libraryText,
            "1 track"
        )
    }
}
