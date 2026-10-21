import Foundation

public enum SourcePreflightParsingError: Error, Equatable, Sendable {
    case invalidJSON
    case oversized
}

public enum SourcePreflightParser {
    public static let maximumJSONBytes = 2_097_152

    public static func parse(_ data: Data) throws -> SourcePreflightResult {
        guard data.count <= maximumJSONBytes else {
            throw SourcePreflightParsingError.oversized
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw SourcePreflightParsingError.invalidJSON
        }

        let selected = payload.requestedDownloads?.first ?? payload.topLevelFormat
        let audio = SelectedSourceAudio(
            codec: normalizedCodec(selected.codec),
            bitrateKbps: selected.bitrate?.roundedInteger,
            sampleRateHz: selected.sampleRate?.roundedInteger
        )

        return SourcePreflightResult(
            title: payload.title,
            uploader: payload.uploader,
            durationSeconds: payload.duration?.value,
            selectedAudio: audio,
            assessment: SourceAssessment.assess(audio)
        )
    }

    private static func normalizedCodec(_ codec: String?) -> String? {
        guard let codec, !codec.isEmpty, codec.lowercased() != "none" else { return nil }
        return codec
    }

    private struct Payload: Decodable {
        let title: String?
        let uploader: String?
        let duration: NumericValue?
        let topLevelFormat: FormatFacts
        let requestedDownloads: [FormatFacts]?

        enum CodingKeys: String, CodingKey {
            case title
            case uploader
            case duration
            case codec = "acodec"
            case bitrate = "abr"
            case sampleRate = "asr"
            case requestedDownloads = "requested_downloads"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            uploader = try container.decodeIfPresent(String.self, forKey: .uploader)
            duration = try container.decodeIfPresent(NumericValue.self, forKey: .duration)
            topLevelFormat = FormatFacts(
                codec: try container.decodeIfPresent(String.self, forKey: .codec),
                bitrate: try container.decodeIfPresent(NumericValue.self, forKey: .bitrate),
                sampleRate: try container.decodeIfPresent(NumericValue.self, forKey: .sampleRate)
            )
            requestedDownloads = try container.decodeIfPresent([FormatFacts].self, forKey: .requestedDownloads)
        }
    }

    private struct FormatFacts: Decodable {
        let codec: String?
        let bitrate: NumericValue?
        let sampleRate: NumericValue?

        enum CodingKeys: String, CodingKey {
            case codec = "acodec"
            case bitrate = "abr"
            case sampleRate = "asr"
        }
    }

    private enum NumericValue: Decodable {
        case number(Double)
        case string(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        var value: Double? {
            switch self {
            case .number(let value): value
            case .string(let value): Double(value)
            }
        }

        var roundedInteger: Int? {
            value.map { Int($0.rounded()) }
        }
    }
}
