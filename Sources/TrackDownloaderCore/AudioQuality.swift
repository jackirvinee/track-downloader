import Foundation

public enum QualityVerdict: String, Codable, Equatable {
    case low
    case borderline
    case good
    case excellent
    case unknown

    public var displayName: String {
        rawValue.capitalized
    }

    public var shouldFindBetterSource: Bool {
        self == .low || self == .borderline || self == .unknown
    }

    public var resultSummary: String {
        switch self {
        case .low:
            return "Saved source is limited quality. Find a better source if you need a cleaner file."
        case .borderline:
            return "Saved source is usable but limited quality. Find a better source if you need a cleaner file."
        case .good:
            return "Saved source has good measured audio quality."
        case .excellent:
            return "Saved source has excellent measured audio quality."
        case .unknown:
            return "Saved source quality could not be measured."
        }
    }
}

public struct AudioQuality: Equatable {
    public let fileURL: URL
    public let codec: String
    public let kbps: Int?
    public let sampleRateHz: Int?
    public let verdict: QualityVerdict

    public init(
        fileURL: URL,
        codec: String,
        kbps: Int?,
        sampleRateHz: Int?,
        verdict: QualityVerdict
    ) {
        self.fileURL = fileURL
        self.codec = codec
        self.kbps = kbps
        self.sampleRateHz = sampleRateHz
        self.verdict = verdict
    }

    public static func classify(kbps: Int?) -> QualityVerdict {
        guard let kbps else { return .unknown }
        if kbps >= 256 { return .excellent }
        if kbps >= 160 { return .good }
        if kbps >= 128 { return .borderline }
        return .low
    }

    public var bitrateLabel: String {
        kbps.map { "\($0) kbps" } ?? "Unknown bitrate"
    }

    public var sampleRateLabel: String? {
        guard let sampleRateHz else { return nil }
        let khz = Double(sampleRateHz) / 1_000
        return khz.rounded() == khz
            ? "\(Int(khz)) kHz"
            : String(format: "%.1f kHz", khz)
    }

    public var reportLine: String {
        let sampleRate = sampleRateLabel.map { ", \($0)" } ?? ""
        return "\(bitrateLabel) \(codec)\(sampleRate) - \(verdict.rawValue)"
    }
}

public enum AudioQualityParser {
    private struct ProbePayload: Decodable {
        let streams: [ProbeStream]
        let format: ProbeFormat?
    }

    private struct ProbeStream: Decodable {
        let codecType: String?
        let codecName: String?
        let bitRate: String?
        let sampleRate: String?

        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type"
            case codecName = "codec_name"
            case bitRate = "bit_rate"
            case sampleRate = "sample_rate"
        }
    }

    private struct ProbeFormat: Decodable {
        let bitRate: String?

        enum CodingKeys: String, CodingKey {
            case bitRate = "bit_rate"
        }
    }

    public static func parse(_ data: Data, fileURL: URL) throws -> AudioQuality {
        let payload = try JSONDecoder().decode(ProbePayload.self, from: data)
        let stream = payload.streams.first { $0.codecType == "audio" }
        let bitrate = integer(stream?.bitRate) ?? integer(payload.format?.bitRate)
        let kbps = bitrate.map { Int((Double($0) / 1_000).rounded()) }

        return AudioQuality(
            fileURL: fileURL,
            codec: stream?.codecName ?? "unknown",
            kbps: kbps,
            sampleRateHz: integer(stream?.sampleRate),
            verdict: AudioQuality.classify(kbps: kbps)
        )
    }

    private static func integer(_ value: String?) -> Int? {
        guard let value, value != "N/A" else { return nil }
        return Int(value)
    }
}
