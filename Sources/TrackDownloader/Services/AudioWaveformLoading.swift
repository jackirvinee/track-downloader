import Accelerate
import AVFoundation
import Foundation

protocol AudioWaveformLoading: Sendable {
    func loadWaveform(from fileURL: URL) async -> WaveformProjection
}

actor AudioWaveformLoader: AudioWaveformLoading {
    private let bucketCount: Int
    private let framesPerBucket: AVAudioFrameCount
    private var cache: [CacheKey: WaveformProjection] = [:]

    init(bucketCount: Int = 256, framesPerBucket: AVAudioFrameCount = 4_096) {
        self.bucketCount = max(bucketCount, 1)
        self.framesPerBucket = max(framesPerBucket, 64)
    }

    func loadWaveform(from fileURL: URL) async -> WaveformProjection {
        guard fileURL.isFileURL, !Task.isCancelled,
              let key = CacheKey(fileURL: fileURL) else { return .unavailable }
        if let cached = cache[key] { return cached }
        let projection = Self.analyse(
            fileURL,
            bucketCount: bucketCount,
            framesPerBucket: framesPerBucket
        )
        guard !Task.isCancelled else { return .unavailable }
        cache[key] = projection
        return projection
    }

    private static func analyse(
        _ fileURL: URL,
        bucketCount: Int,
        framesPerBucket: AVAudioFrameCount
    ) -> WaveformProjection {
        guard !Task.isCancelled,
              let file = try? AVAudioFile(forReading: fileURL),
              file.length > 0 else {
            return .unavailable
        }

        let format = file.processingFormat
        guard format.sampleRate.isFinite,
              format.sampleRate > 0,
              format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32 else {
            return .unavailable
        }

        let requestedFrameCount = min(
            framesPerBucket,
            AVAudioFrameCount(Self.maximumAnalysisFrameCount),
            AVAudioFrameCount(clamping: file.length)
        )
        let dftFrameCount = Self.nextPowerOfTwo(Int(requestedFrameCount))
        guard requestedFrameCount > 0,
              let setup = vDSP_DFT_zop_CreateSetup(
                  nil,
                  vDSP_Length(dftFrameCount),
                  .FORWARD
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: requestedFrameCount
              ) else {
            return .unavailable
        }
        defer { vDSP_DFT_DestroySetup(setup) }

        let maximumStart = max(file.length - AVAudioFramePosition(requestedFrameCount), 0)
        var rawBuckets: [RawBucket] = []
        rawBuckets.reserveCapacity(bucketCount)

        for bucketIndex in 0..<bucketCount {
            guard !Task.isCancelled else { return .unavailable }

            let progress = bucketCount == 1
                ? 0
                : Double(bucketIndex) / Double(bucketCount - 1)
            file.framePosition = AVAudioFramePosition(
                (Double(maximumStart) * progress).rounded()
            )

            do {
                try file.read(into: buffer, frameCount: requestedFrameCount)
            } catch {
                return .unavailable
            }

            guard buffer.frameLength > 0,
                  let channels = buffer.floatChannelData else {
                return .unavailable
            }

            var inputReal = [Float](repeating: 0, count: dftFrameCount)
            var inputImaginary = [Float](repeating: 0, count: dftFrameCount)
            var squaredSampleSum = 0.0
            for frameIndex in 0..<Int(buffer.frameLength) {
                var peakSample: Float = 0
                for channelIndex in 0..<Int(format.channelCount) {
                    let sample = channels[channelIndex][frameIndex]
                    guard sample.isFinite else { return .unavailable }
                    if abs(sample) > abs(peakSample) {
                        peakSample = sample
                    }
                }
                squaredSampleSum += Double(peakSample * peakSample)
                let windowPosition = buffer.frameLength == 1
                    ? 0
                    : Double(frameIndex) / Double(buffer.frameLength - 1)
                let hannWindow = 0.5 - 0.5 * cos(2 * .pi * windowPosition)
                inputReal[frameIndex] = peakSample * Float(hannWindow)
            }

            var outputReal = [Float](repeating: 0, count: dftFrameCount)
            var outputImaginary = [Float](repeating: 0, count: dftFrameCount)
            vDSP_DFT_Execute(
                setup,
                &inputReal,
                &inputImaginary,
                &outputReal,
                &outputImaginary
            )

            let magnitudes = zip(outputReal, outputImaginary).map { real, imaginary in
                hypot(Double(real), Double(imaginary))
            }
            let rawBucket = RawBucket(
                amplitude: sqrt(squaredSampleSum / Double(buffer.frameLength)),
                low: bandEnergy(
                    magnitudes,
                    dftFrameCount: dftFrameCount,
                    sampleRate: format.sampleRate,
                    lowerFrequency: 20,
                    upperFrequency: 200
                ),
                mid: bandEnergy(
                    magnitudes,
                    dftFrameCount: dftFrameCount,
                    sampleRate: format.sampleRate,
                    lowerFrequency: 200,
                    upperFrequency: 2_000
                ),
                high: bandEnergy(
                    magnitudes,
                    dftFrameCount: dftFrameCount,
                    sampleRate: format.sampleRate,
                    lowerFrequency: 2_000,
                    upperFrequency: 12_000,
                    includesUpperFrequency: true
                )
            )
            guard rawBucket.isFinite else { return .unavailable }
            rawBuckets.append(rawBucket)
        }

        guard rawBuckets.count == bucketCount else { return .unavailable }
        let maximumAmplitude = rawBuckets.reduce(0) { maximum, bucket in
            max(maximum, bucket.amplitude)
        }
        let maximumLowEnergy = rawBuckets.reduce(0) { max($0, $1.low) }
        let maximumMidEnergy = rawBuckets.reduce(0) { max($0, $1.mid) }
        let maximumHighEnergy = rawBuckets.reduce(0) { max($0, $1.high) }
        let maximumBandEnergy = max(
            maximumLowEnergy,
            maximumMidEnergy,
            maximumHighEnergy
        )
        let amplitudeDivisor = maximumAmplitude > 0 ? maximumAmplitude : 1
        return WaveformProjection(
            buckets: rawBuckets.map { bucket in
                let amplitude = pow(bucket.amplitude / amplitudeDivisor, 0.55)
                let redEnergy = Self.trackRelativeColorEnergy(
                    bucket.low,
                    bandMaximum: maximumLowEnergy,
                    maximumBandEnergy: maximumBandEnergy
                )
                let greenEnergy = Self.trackRelativeColorEnergy(
                    bucket.mid,
                    bandMaximum: maximumMidEnergy,
                    maximumBandEnergy: maximumBandEnergy
                )
                let blueEnergy = Self.trackRelativeColorEnergy(
                    bucket.high,
                    bandMaximum: maximumHighEnergy,
                    maximumBandEnergy: maximumBandEnergy
                )
                let maximumColorEnergy = max(redEnergy, greenEnergy, blueEnergy)
                guard maximumColorEnergy > 0 else {
                    return WaveformBucket(low: 0, mid: 0, high: 0)
                }
                let visibleEnergyFloor = maximumColorEnergy * 0.001
                return WaveformBucket(
                    low: amplitude * Self.normalizedColorEnergy(
                        redEnergy,
                        maximum: maximumColorEnergy,
                        floor: visibleEnergyFloor
                    ),
                    mid: amplitude * Self.normalizedColorEnergy(
                        greenEnergy,
                        maximum: maximumColorEnergy,
                        floor: visibleEnergyFloor
                    ),
                    high: amplitude * Self.normalizedColorEnergy(
                        blueEnergy,
                        maximum: maximumColorEnergy,
                        floor: visibleEnergyFloor
                    )
                )
            }
        )
    }

    private static func bandEnergy(
        _ magnitudes: [Double],
        dftFrameCount: Int,
        sampleRate: Double,
        lowerFrequency: Double,
        upperFrequency: Double,
        includesUpperFrequency: Bool = false
    ) -> Double {
        let nyquistBinCount = dftFrameCount / 2
        var squaredMagnitudeSum = 0.0
        for bin in 0...nyquistBinCount {
            let frequency = Double(bin) * sampleRate / Double(dftFrameCount)
            guard frequency >= lowerFrequency,
                  frequency < upperFrequency || (includesUpperFrequency && frequency == upperFrequency),
                  bin < magnitudes.count else {
                continue
            }
            squaredMagnitudeSum += magnitudes[bin] * magnitudes[bin]
        }
        return sqrt(squaredMagnitudeSum)
    }

    private static func normalizedColorEnergy(
        _ energy: Double,
        maximum: Double,
        floor: Double
    ) -> Double {
        energy >= floor ? energy / maximum : 0
    }

    private static func trackRelativeColorEnergy(
        _ energy: Double,
        bandMaximum: Double,
        maximumBandEnergy: Double
    ) -> Double {
        guard maximumBandEnergy > 0 else { return 0 }
        let bandIsAudible = bandMaximum >= maximumBandEnergy * 0.02
        let divisor = bandIsAudible ? bandMaximum : maximumBandEnergy
        guard divisor > 0 else { return 0 }
        return pow(min(max(energy / divisor, 0), 1), 0.65)
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        guard value > 1 else { return 1 }
        return 1 << (Int.bitWidth - (value - 1).leadingZeroBitCount)
    }

    private static let maximumAnalysisFrameCount = 8_192
}

private struct CacheKey: Hashable {
    let standardizedPath: String
    let contentModificationDate: Date

    init?(fileURL: URL) {
        guard let values = try? fileURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ), let contentModificationDate = values.contentModificationDate else {
            return nil
        }
        standardizedPath = fileURL.standardizedFileURL.path
        self.contentModificationDate = contentModificationDate
    }
}

private struct RawBucket {
    let amplitude: Double
    let low: Double
    let mid: Double
    let high: Double

    var isFinite: Bool {
        amplitude.isFinite && low.isFinite && mid.isFinite && high.isFinite
    }
}
