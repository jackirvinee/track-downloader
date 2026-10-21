import XCTest
@testable import TrackDownloaderCore

final class SourcePreflightParserTests: XCTestCase {
    func testUsesRequestedDownloadFormatInsteadOfTopLevelOrAvailableFormats() throws {
        let result = try SourcePreflightParser.parse(Data("""
        {
          "title": "Night Drive",
          "uploader": "Example Artist",
          "duration": 245.4,
          "acodec": "aac",
          "abr": 96,
          "asr": 44100,
          "requested_downloads": [
            {"acodec": "opus", "abr": 192.4, "asr": 48000}
          ],
          "formats": [
            {"acodec": "mp3", "abr": 320, "asr": 48000}
          ]
        }
        """.utf8))

        XCTAssertEqual(result.title, "Night Drive")
        XCTAssertEqual(result.uploader, "Example Artist")
        XCTAssertEqual(result.durationSeconds, 245.4)
        XCTAssertEqual(result.selectedAudio.codec, "opus")
        XCTAssertEqual(result.selectedAudio.bitrateKbps, 192)
        XCTAssertEqual(result.selectedAudio.sampleRateHz, 48_000)
        XCTAssertEqual(result.assessment, .compatibleExportLikely)
        XCTAssertEqual(result.assessment.title, "Compatible export likely")
    }

    func testKeepsAbsentMetadataAndSelectedAudioFactsUnknown() throws {
        let result = try SourcePreflightParser.parse(Data("{}".utf8))

        XCTAssertNil(result.title)
        XCTAssertNil(result.uploader)
        XCTAssertNil(result.durationSeconds)
        XCTAssertNil(result.selectedAudio.codec)
        XCTAssertNil(result.selectedAudio.bitrateKbps)
        XCTAssertNil(result.selectedAudio.sampleRateHz)
        XCTAssertEqual(result.assessment, .findBetterSource)
        XCTAssertEqual(result.assessment.title, "Find a better source")
    }

    func testFallsBackOnlyToTopLevelSelectedFormatWhenRequestedDownloadsAreAbsent() throws {
        let result = try SourcePreflightParser.parse(Data("""
        {
          "acodec": "aac",
          "abr": "192.4",
          "asr": "44100",
          "formats": [
            {"acodec": "flac", "abr": 900, "asr": 96000}
          ]
        }
        """.utf8))

        XCTAssertEqual(result.selectedAudio.codec, "aac")
        XCTAssertEqual(result.selectedAudio.bitrateKbps, 192)
        XCTAssertEqual(result.selectedAudio.sampleRateHz, 44_100)
        XCTAssertEqual(result.assessment, .readyToDownload)
        XCTAssertEqual(result.assessment.title, "Ready to download")
    }

    func testNeverInfersSelectedAudioFromUnselectedFormats() throws {
        let result = try SourcePreflightParser.parse(Data("""
        {
          "formats": [
            {"acodec": "flac", "abr": 900, "asr": 96000}
          ]
        }
        """.utf8))

        XCTAssertNil(result.selectedAudio.codec)
        XCTAssertNil(result.selectedAudio.bitrateKbps)
        XCTAssertNil(result.selectedAudio.sampleRateHz)
        XCTAssertEqual(result.assessment, .findBetterSource)
    }

    func testOnlyFormatsEveryDeckPlaysAreReadyWithoutConversion() {
        func assessment(_ codec: String, _ rate: Int) -> SourceAssessment {
            SourceAssessment.assess(SelectedSourceAudio(codec: codec, bitrateKbps: 900, sampleRateHz: rate))
        }

        XCTAssertEqual(assessment("mp4a.40.2", 44_100), .readyToDownload)
        XCTAssertEqual(assessment("mp3", 44_100), .readyToDownload)
        XCTAssertEqual(assessment("pcm_s24le", 48_000), .readyToDownload)
        // FLAC/ALAC only play on the NXS2/3000, so they need the post-download WAV conversion.
        XCTAssertEqual(assessment("flac", 44_100), .compatibleExportLikely)
        XCTAssertEqual(assessment("alac", 44_100), .compatibleExportLikely)
        XCTAssertEqual(assessment("mp4a.40.5", 44_100), .compatibleExportLikely)
        XCTAssertEqual(assessment("pcm_s24le", 96_000), .compatibleExportLikely)
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try SourcePreflightParser.parse(Data("{".utf8))) { error in
            XCTAssertEqual(error as? SourcePreflightParsingError, .invalidJSON)
        }
    }

    func testRejectsOversizedJSONBeforeDecoding() {
        let oversized = Data(repeating: 0x20, count: SourcePreflightParser.maximumJSONBytes + 1)

        XCTAssertThrowsError(try SourcePreflightParser.parse(oversized)) { error in
            XCTAssertEqual(error as? SourcePreflightParsingError, .oversized)
        }
    }

    func testRoundsFractionalBitrateAndTreatsNoneOrEmptyCodecsAsUnknown() throws {
        let noneCodec = try SourcePreflightParser.parse(Data("""
        {"acodec": "none", "abr": 191.6, "asr": 48000}
        """.utf8))
        let emptyCodec = try SourcePreflightParser.parse(Data("""
        {"acodec": "", "abr": "191.6", "asr": "48000"}
        """.utf8))

        [noneCodec, emptyCodec].forEach { result in
            XCTAssertNil(result.selectedAudio.codec)
            XCTAssertEqual(result.selectedAudio.bitrateKbps, 192)
            XCTAssertEqual(result.selectedAudio.sampleRateHz, 48_000)
            XCTAssertEqual(result.assessment, .findBetterSource)
        }
    }

    func testKeepsPreflightEstimateDistinctFromSavedFileMeasurement() throws {
        let preflight = try SourcePreflightParser.parse(Data("""
        {"acodec": "opus", "abr": 192, "asr": 48000}
        """.utf8))
        let savedQuality = AudioQuality(
            fileURL: URL(fileURLWithPath: "/tmp/night-drive.m4a"),
            codec: "aac",
            kbps: 128,
            sampleRateHz: 44_100,
            verdict: .borderline
        )

        XCTAssertEqual(preflight.selectedAudio.bitrateKbps, 192)
        XCTAssertEqual(preflight.assessment, .compatibleExportLikely)
        XCTAssertEqual(savedQuality.kbps, 128)
        XCTAssertEqual(savedQuality.verdict, .borderline)
    }
}
