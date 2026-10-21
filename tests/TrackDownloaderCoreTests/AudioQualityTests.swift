import XCTest
@testable import TrackDownloaderCore

final class AudioQualityTests: XCTestCase {
    func testParsesStreamBitrateAndClassifiesQuality() throws {
        let json = """
        {
          "streams": [{
            "codec_type": "audio",
            "codec_name": "opus",
            "bit_rate": "161200",
            "sample_rate": "48000"
          }],
          "format": {"bit_rate": "170000"}
        }
        """

        let quality = try AudioQualityParser.parse(
            Data(json.utf8),
            fileURL: URL(fileURLWithPath: "/tmp/track.opus")
        )

        XCTAssertEqual(quality.codec, "opus")
        XCTAssertEqual(quality.kbps, 161)
        XCTAssertEqual(quality.sampleRateHz, 48_000)
        XCTAssertEqual(quality.verdict, .good)
    }

    func testFallsBackToContainerBitrate() throws {
        let json = """
        {
          "streams": [{
            "codec_type": "audio",
            "codec_name": "aac",
            "sample_rate": "44100"
          }],
          "format": {"bit_rate": "127600"}
        }
        """

        let quality = try AudioQualityParser.parse(
            Data(json.utf8),
            fileURL: URL(fileURLWithPath: "/tmp/track.m4a")
        )

        XCTAssertEqual(quality.kbps, 128)
        XCTAssertEqual(quality.verdict, .borderline)
    }

    func testQualityThresholdsProtectDJUseCase() {
        XCTAssertEqual(AudioQuality.classify(kbps: 64), .low)
        XCTAssertEqual(AudioQuality.classify(kbps: 159), .borderline)
        XCTAssertEqual(AudioQuality.classify(kbps: 160), .good)
        XCTAssertEqual(AudioQuality.classify(kbps: 256), .excellent)
        XCTAssertEqual(AudioQuality.classify(kbps: nil), .unknown)
    }

    func testLimitedQualityVerdictsStateThatTheSavedSourceIsLimited() {
        XCTAssertEqual(
            QualityVerdict.low.resultSummary,
            "Saved source is limited quality. Find a better source if you need a cleaner file."
        )
        XCTAssertEqual(
            QualityVerdict.borderline.resultSummary,
            "Saved source is usable but limited quality. Find a better source if you need a cleaner file."
        )
    }

    func testGoodAndExcellentVerdictsDescribeTheMeasuredFileWithoutUpscalingClaims() {
        XCTAssertEqual(
            QualityVerdict.good.resultSummary,
            "Saved source has good measured audio quality."
        )
        XCTAssertEqual(
            QualityVerdict.excellent.resultSummary,
            "Saved source has excellent measured audio quality."
        )
    }

    func testUnknownVerdictDoesNotInventQualityAndExplainsTheMeasurementGap() {
        XCTAssertEqual(
            QualityVerdict.unknown.resultSummary,
            "Saved source quality could not be measured."
        )
    }
}
