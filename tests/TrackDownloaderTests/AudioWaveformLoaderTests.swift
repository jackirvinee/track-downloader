import AVFoundation
import XCTest
@testable import TrackDownloader

final class AudioWaveformLoaderTests: XCTestCase {
    func testLocalWAVProducesBoundedBucketsAndCachesByFileVersion() async throws {
        let fileURL = try makeWAV(samples: (0..<4_096).map { index in
            sin(Double(index) * .pi / 16) * (index < 2_048 ? 0.25 : 0.8)
        })
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let loader = AudioWaveformLoader(bucketCount: 8, framesPerBucket: 256)

        let first = await loader.loadWaveform(from: fileURL)
        let second = await loader.loadWaveform(from: fileURL)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.buckets.count, 8)
        XCTAssertTrue(first.buckets.allSatisfy { (0...1).contains($0.low) && (0...1).contains($0.mid) && (0...1).contains($0.high) })
    }

    func testNonFileURLReportsUnavailable() async {
        let result = await AudioWaveformLoader().loadWaveform(from: URL(string: "https://example.com/audio")!)
        XCTAssertEqual(result, .unavailable)
    }

    func testHighBandIncludesTwelveKilohertzEndpoint() async throws {
        let sampleRate = 48_000.0
        let fileURL = try makeWAV(
            samples: (0..<1_024).map { index in
                sin(2 * .pi * 12_000 * Double(index) / sampleRate)
            },
            sampleRate: sampleRate
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let projection = await AudioWaveformLoader(
            bucketCount: 1,
            framesPerBucket: 1_024
        ).loadWaveform(from: fileURL)

        let bucket = try XCTUnwrap(projection.buckets.first)
        XCTAssertEqual(bucket.high, 1, accuracy: 0.000_001)
        XCTAssertLessThan(bucket.low, 0.000_001)
        XCTAssertLessThan(bucket.mid, 0.000_001)
    }

    func testEqualStrengthBassMidAndTrebleRemainVisibleInThreeBandLayers() async throws {
        let sampleRate = 48_000.0
        let fileURL = try makeWAV(
            samples: (0..<8_192).map { index in
                let time = Double(index) / sampleRate
                return 0.2 * sin(2 * .pi * 100 * time)
                    + 0.2 * sin(2 * .pi * 700 * time)
                    + 0.2 * sin(2 * .pi * 5_000 * time)
            },
            sampleRate: sampleRate
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let projection = await AudioWaveformLoader(
            bucketCount: 1,
            framesPerBucket: 8_192
        ).loadWaveform(from: fileURL)

        let bucket = try XCTUnwrap(projection.buckets.first)
        XCTAssertGreaterThan(bucket.low, 0.5)
        XCTAssertGreaterThan(bucket.mid, 0.5)
        XCTAssertGreaterThan(bucket.high, 0.5)
    }

    func testTrackRelativeBandBalanceRevealsMidAndTrebleSections() async throws {
        let sampleRate = 48_000.0
        let framesPerSection = 8_192
        let sections = [
            (bass: 0.4, mid: 0.02, treble: 0.01),
            (bass: 0.4, mid: 0.15, treble: 0.01),
            (bass: 0.4, mid: 0.02, treble: 0.12),
        ]
        let samples = sections.flatMap { levels in
            (0..<framesPerSection).map { index in
                let time = Double(index) / sampleRate
                return levels.bass * sin(2 * .pi * 100 * time)
                    + levels.mid * sin(2 * .pi * 700 * time)
                    + levels.treble * sin(2 * .pi * 5_000 * time)
            }
        }
        let fileURL = try makeWAV(samples: samples, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let projection = await AudioWaveformLoader(
            bucketCount: 3,
            framesPerBucket: AVAudioFrameCount(framesPerSection)
        ).loadWaveform(from: fileURL)
        let buckets = projection.buckets

        XCTAssertEqual(buckets.count, 3)
        XCTAssertGreaterThan(buckets[0].low, buckets[0].mid)
        XCTAssertGreaterThan(buckets[0].low, buckets[0].high)
        XCTAssertGreaterThan(buckets[1].mid, 0.85)
        XCTAssertGreaterThan(buckets[2].high, 0.85)
    }
}

private func makeWAV(samples: [Double], sampleRate: Double = 44_100) throws -> URL {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioWaveformLoaderTests-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    let format = try XCTUnwrap(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
    )
    let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )
    )
    buffer.frameLength = buffer.frameCapacity
    let channel = try XCTUnwrap(buffer.floatChannelData?[0])
    for (index, sample) in samples.enumerated() {
        channel[index] = Float(sample)
    }

    let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
    try file.write(from: buffer)
    return fileURL
}
