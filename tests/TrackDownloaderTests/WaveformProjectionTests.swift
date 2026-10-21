import XCTest
@testable import TrackDownloader

final class WaveformProjectionTests: XCTestCase {
    func testBandClampsFiniteAndNonfiniteLevels() {
        XCTAssertEqual(WaveformBand(level: -0.2).level, 0)
        XCTAssertEqual(WaveformBand(level: 0.5).level, 0.5)
        XCTAssertEqual(WaveformBand(level: 1.4).level, 1)
        XCTAssertEqual(WaveformBand(level: .nan).level, 0)
    }

    func testBucketsClampAndDescribeLocalBandLevels() {
        let projection = WaveformProjection(buckets: [
            .init(low: -0.2, mid: 0.5, high: 1.4)
        ])
        XCTAssertEqual(projection.buckets, [.init(low: 0, mid: 0.5, high: 1)])
        XCTAssertEqual(projection.accessibilityLabel, "Three-band waveform overview with 1 bucket")
    }

    func testUnavailableProjectionNeverClaimsAudioAnalysis() {
        XCTAssertTrue(WaveformProjection.unavailable.isUnavailable)
        XCTAssertEqual(WaveformProjection.unavailable.accessibilityLabel, "Waveform unavailable")
    }

    func testRenderSamplePreservesThreeBandFrequencyOwnership() {
        let sample = WaveformRenderSample(bucket: .init(low: 0.6, mid: 0.3, high: 0.1))

        XCTAssertEqual(sample.lowAmplitude, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(sample.midAmplitude, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(sample.highAmplitude, 0.1, accuracy: 0.000_001)
    }

    func testRenderSampleKeepsPureBandsIsolated() {
        let low = WaveformRenderSample(bucket: .init(low: 0.6, mid: 0, high: 0))
        XCTAssertEqual(low.lowAmplitude, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(low.midAmplitude, 0, accuracy: 0.000_001)
        XCTAssertEqual(low.highAmplitude, 0, accuracy: 0.000_001)

        let mid = WaveformRenderSample(bucket: .init(low: 0, mid: 0.6, high: 0))
        XCTAssertEqual(mid.lowAmplitude, 0, accuracy: 0.000_001)
        XCTAssertEqual(mid.midAmplitude, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(mid.highAmplitude, 0, accuracy: 0.000_001)

        let high = WaveformRenderSample(bucket: .init(low: 0, mid: 0, high: 0.6))
        XCTAssertEqual(high.lowAmplitude, 0, accuracy: 0.000_001)
        XCTAssertEqual(high.midAmplitude, 0, accuracy: 0.000_001)
        XCTAssertEqual(high.highAmplitude, 0.6, accuracy: 0.000_001)
    }

    func testRenderSamplesDownsampleWithoutLosingPeakBandEnergy() {
        let projection = WaveformProjection(buckets: [
            .init(low: 0.8, mid: 0.1, high: 0.2),
            .init(low: 0.2, mid: 0.6, high: 0.3),
            .init(low: 0.1, mid: 0.2, high: 0.5),
            .init(low: 0.4, mid: 0.3, high: 0.9),
        ])

        XCTAssertEqual(
            projection.renderSamples(maximumCount: 2),
            [
                WaveformRenderSample(bucket: .init(low: 0.8, mid: 0.6, high: 0.3)),
                WaveformRenderSample(bucket: .init(low: 0.4, mid: 0.3, high: 0.9)),
            ]
        )
        XCTAssertEqual(projection.renderSamples(maximumCount: 0), [])
    }
}
