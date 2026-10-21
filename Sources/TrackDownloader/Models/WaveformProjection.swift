import Foundation

struct WaveformBand: Equatable {
    let level: Double

    init(level: Double) {
        self.level = min(max(level.isFinite ? level : 0, 0), 1)
    }
}

struct WaveformBucket: Equatable {
    let low: Double
    let mid: Double
    let high: Double

    init(low: Double, mid: Double, high: Double) {
        self.low = Self.clamp(low)
        self.mid = Self.clamp(mid)
        self.high = Self.clamp(high)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}

struct WaveformRenderSample: Equatable {
    let lowAmplitude: Double
    let midAmplitude: Double
    let highAmplitude: Double

    init(bucket: WaveformBucket) {
        lowAmplitude = bucket.low
        midAmplitude = bucket.mid
        highAmplitude = bucket.high
    }
}

struct WaveformProjection: Equatable {
    let buckets: [WaveformBucket]
    let isUnavailable: Bool

    init(buckets: [WaveformBucket]) {
        self.buckets = buckets
        isUnavailable = buckets.isEmpty
    }

    static let unavailable = WaveformProjection(buckets: [])

    var accessibilityLabel: String {
        guard !isUnavailable else { return "Waveform unavailable" }
        return "Three-band waveform overview with \(buckets.count) \(buckets.count == 1 ? "bucket" : "buckets")"
    }

    func renderSamples(maximumCount: Int) -> [WaveformRenderSample] {
        guard maximumCount > 0, !buckets.isEmpty else { return [] }
        guard buckets.count > maximumCount else {
            return buckets.map(WaveformRenderSample.init)
        }

        return (0..<maximumCount).map { outputIndex in
            let lowerBound = outputIndex * buckets.count / maximumCount
            let upperBound = max(
                lowerBound + 1,
                (outputIndex + 1) * buckets.count / maximumCount
            )
            let sourceBuckets = buckets[lowerBound..<min(upperBound, buckets.count)]
            let peakBucket = sourceBuckets.reduce(
                WaveformBucket(low: 0, mid: 0, high: 0)
            ) { peak, bucket in
                WaveformBucket(
                    low: max(peak.low, bucket.low),
                    mid: max(peak.mid, bucket.mid),
                    high: max(peak.high, bucket.high)
                )
            }
            return WaveformRenderSample(bucket: peakBucket)
        }
    }
}
