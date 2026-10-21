import TrackDownloaderCore
import XCTest
@testable import TrackDownloader

final class LibraryPresentationTests: XCTestCase {
    func testCompactToolbarPreservesReadableSearchWidthAtMinimumPaneSize() {
        let metrics = LibraryToolbarMetrics()

        XCTAssertEqual(metrics.searchWidth(in: 520), 144)
        XCTAssertGreaterThanOrEqual(
            metrics.searchWidth(in: 520),
            metrics.minimumSearchWidth
        )
    }

    func testConcreteLibraryStatesNameConditionAndNextAction() {
        XCTAssertEqual(LibraryContentPresentation.resolve(isOutputDirectoryAvailable: false, visibleTrackCount: 0, hasSearchQuery: false, destinationTitle: "All Tracks"), .unavailable(title: "Output folder unavailable", detail: "Refresh the library or open the output folder in Finder."))
        XCTAssertEqual(LibraryContentPresentation.resolve(isOutputDirectoryAvailable: true, visibleTrackCount: 0, hasSearchQuery: true, destinationTitle: "All Tracks"), .noMatches(title: "No matching tracks", detail: "Clear the search or choose another scope."))
        XCTAssertEqual(LibraryContentPresentation.resolve(isOutputDirectoryAvailable: true, visibleTrackCount: 0, hasSearchQuery: false, destinationTitle: "Opening Set"), .empty(title: "Opening Set is empty", detail: "Choose another scope or add a selected track to this crate."))
    }

    func testPopulatedStateWinsWhenTracksAreVisible() {
        XCTAssertEqual(
            LibraryContentPresentation.resolve(
                isOutputDirectoryAvailable: true,
                visibleTrackCount: 2,
                hasSearchQuery: true,
                destinationTitle: "All Tracks"
            ),
            .populated
        )
    }

    func testVisibleColumnsMenuCopyExplainsFieldSelection() {
        let source = try! String(contentsOfFile: "Sources/TrackDownloader/Views/DownloadedTracksView.swift")
        XCTAssertTrue(source.contains("Visible Columns"))
        XCTAssertTrue(source.contains("Choose the fields shown in the Library table."))
        XCTAssertTrue(source.contains("Reorder Visible Columns"))
    }

    func testSelectionDetailKeepsLocalFactsReadableAtLargerTextSizes() {
        let source = try! String(contentsOfFile: "Sources/TrackDownloader/Views/LibrarySelectionDetailView.swift")
        XCTAssertTrue(source.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(source.contains("Show in Finder"))
        XCTAssertTrue(source.contains("Find Better Source"))
    }
}
