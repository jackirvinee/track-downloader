import XCTest
@testable import TrackDownloaderCore

final class DownloadCommandBuilderTests: XCTestCase {
    func testOmitsBrowserCookiesByDefault() {
        let output = URL(fileURLWithPath: "/tmp/TrackDownloader Output", isDirectory: true)
        let source = URL(string: "https://youtu.be/example")!

        let command = DownloadCommandBuilder.arguments(
            sourceURL: source,
            outputDirectory: output
        )

        XCTAssertFalse(command.contains("--cookies-from-browser"))
    }

    func testBuildsBestQualityMetadataPreservingCommand() {
        let output = URL(fileURLWithPath: "/tmp/TrackDownloader Output", isDirectory: true)
        let source = URL(string: "https://soundcloud.com/artist/track")!

        let command = DownloadCommandBuilder.arguments(
            sourceURL: source,
            outputDirectory: output,
            cookiesBrowser: "chrome"
        )

        XCTAssertTrue(command.contains("bestaudio/best"))
        XCTAssertTrue(command.contains("acodec,abr,asr"))
        XCTAssertTrue(command.containsContiguousSubsequence(YTDLPAudioSelectionPolicy.arguments))
        XCTAssertTrue(command.contains("--embed-metadata"))
        XCTAssertTrue(command.contains("--embed-thumbnail"))
        XCTAssertTrue(command.contains("--write-info-json"))
        XCTAssertFalse(command.contains("--no-progress"))
        XCTAssertEqual(value(after: "--progress-delta", in: command), "0.5")
        XCTAssertEqual(
            value(after: "--progress-template", in: command),
            "download:track-downloader:progress:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"
        )
        XCTAssertTrue(command.contains("postprocess:track-downloader:postprocess:%(progress.postprocessor)s"))
        XCTAssertEqual(value(after: "--print", in: command), "after_move:track-downloader:filepath:%(filepath)s")
        XCTAssertTrue(command.contains("--no-quiet"), "Archive-skip diagnostics must survive --print's implied quiet mode")
        XCTAssertEqual(value(after: "--audio-format", in: command), "best")
        XCTAssertEqual(value(after: "--cookies-from-browser", in: command), "chrome")
        XCTAssertEqual(value(after: "--paths", in: command), output.path)
        XCTAssertEqual(command.last, source.absoluteString)
    }

    func testEnablesOfficialEJSChallengeSolverWithDeno() {
        let output = URL(fileURLWithPath: "/tmp/TrackDownloader Output", isDirectory: true)
        let source = URL(string: "https://youtu.be/example")!

        let command = DownloadCommandBuilder.arguments(
            sourceURL: source,
            outputDirectory: output
        )

        XCTAssertEqual(value(after: "--js-runtimes", in: command), "deno")
        XCTAssertEqual(value(after: "--remote-components", in: command), "ejs:github")
    }

    private func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private extension Array where Element: Equatable {
    func containsContiguousSubsequence(_ subsequence: [Element]) -> Bool {
        guard !subsequence.isEmpty, subsequence.count <= count else { return false }

        return indices.contains { startIndex in
            let endIndex = index(startIndex, offsetBy: subsequence.count, limitedBy: endIndex)
            guard let endIndex else { return false }
            return Array(self[startIndex..<endIndex]) == subsequence
        }
    }
}
