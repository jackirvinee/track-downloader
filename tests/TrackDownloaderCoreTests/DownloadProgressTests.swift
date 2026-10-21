import XCTest
@testable import TrackDownloaderCore

final class DownloadProgressTests: XCTestCase {
    func testParsesMachineProgressRecord() {
        XCTAssertEqual(
            YTDLPOutputParser.parse(line: "track-downloader:progress:42.5|3.2MiB/s|00:12"),
            .progress(percent: 42.5, speed: "3.2MiB/s", eta: "00:12")
        )
    }

    func testParsesPercentSuffixProducedByYTDLPTemplate() {
        XCTAssertEqual(
            YTDLPOutputParser.parse(line: "track-downloader:progress: 42.5%| 3.2MiB/s| 00:12"),
            .progress(percent: 42.5, speed: "3.2MiB/s", eta: "00:12")
        )
    }

    func testClampsMachineProgressRecordToBounds() {
        XCTAssertEqual(
            YTDLPOutputParser.parse(line: "track-downloader:progress:102.4||"),
            .progress(percent: 100, speed: nil, eta: nil)
        )
    }

    func testParsesMachineFinalPathRecord() {
        XCTAssertEqual(
            YTDLPOutputParser.parse(line: "track-downloader:filepath:/tmp/Artist - Track.opus"),
            .finalPath("/tmp/Artist - Track.opus")
        )
    }

    func testParsesMachinePostProcessRecord() {
        XCTAssertEqual(
            YTDLPOutputParser.parse(line: "track-downloader:postprocess:EmbedThumbnail"),
            .postProcess(name: "EmbedThumbnail")
        )
    }

    func testPreservesUnknownOutputAsDiagnostic() {
        XCTAssertEqual(
            YTDLPOutputParser.parse(line: "WARNING: retrying"),
            .diagnostic("WARNING: retrying")
        )
    }
}
