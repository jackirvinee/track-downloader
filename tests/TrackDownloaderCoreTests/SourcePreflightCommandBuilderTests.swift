import Foundation
import XCTest
@testable import TrackDownloaderCore

final class SourcePreflightCommandBuilderTests: XCTestCase {
    func testBuildsSingleItemSimulationWithEstablishedRuntimeAndSelectionPolicy() {
        let source = URL(string: "https://youtu.be/example")!
        let arguments = SourcePreflightCommandBuilder.arguments(sourceURL: source)

        XCTAssertEqual(value(after: "--js-runtimes", in: arguments), "deno")
        XCTAssertEqual(value(after: "--remote-components", in: arguments), "ejs:github")
        XCTAssertEqual(value(after: "--format", in: arguments), "bestaudio/best")
        XCTAssertEqual(value(after: "--format-sort", in: arguments), "acodec,abr,asr")
        XCTAssertTrue(arguments.contains("--dump-single-json"))
        XCTAssertTrue(arguments.contains("--simulate"))
        XCTAssertTrue(arguments.contains("--no-playlist"))
        XCTAssertTrue(arguments.contains("--no-warnings"))
        XCTAssertEqual(arguments.last, source.absoluteString)
    }

    func testOmitsEveryDownloadPersistenceCookieAndPostProcessingOption() {
        let arguments = SourcePreflightCommandBuilder.arguments(
            sourceURL: URL(string: "https://soundcloud.com/artist/track")!
        )
        let forbidden = [
            "--paths", "--output", "--download-archive", "--extract-audio",
            "--audio-format", "--embed-metadata", "--embed-thumbnail",
            "--convert-thumbnails", "--write-info-json", "--cookies-from-browser",
            "--print", "--progress", "--postprocessor-args"
        ]

        forbidden.forEach { XCTAssertFalse(arguments.contains($0), "Unexpected \($0)") }
    }

    private func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
