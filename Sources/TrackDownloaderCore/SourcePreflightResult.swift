public struct SelectedSourceAudio: Equatable, Sendable {
    public let codec: String?
    public let bitrateKbps: Int?
    public let sampleRateHz: Int?

    public init(codec: String?, bitrateKbps: Int?, sampleRateHz: Int?) {
        self.codec = codec
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
    }
}

public enum SourceAssessment: Equatable, Sendable {
    case readyToDownload
    case compatibleExportLikely
    case findBetterSource

    public var title: String {
        switch self {
        case .readyToDownload: "Ready to download"
        case .compatibleExportLikely: "Compatible export likely"
        case .findBetterSource: "Find a better source"
        }
    }

    public static func assess(_ audio: SelectedSourceAudio) -> SourceAssessment {
        guard let bitrate = audio.bitrateKbps,
              AudioQuality.classify(kbps: bitrate) == .good
                || AudioQuality.classify(kbps: bitrate) == .excellent,
              let codec = audio.codec?.lowercased()
        else { return .findBetterSource }

        let directlyCompatible = Set(["aac", "alac", "flac", "mp3", "pcm_s16le", "pcm_s24le"])
        return directlyCompatible.contains(codec) ? .readyToDownload : .compatibleExportLikely
    }
}

public struct SourcePreflightResult: Equatable, Sendable {
    public let title: String?
    public let uploader: String?
    public let durationSeconds: Double?
    public let selectedAudio: SelectedSourceAudio
    public let assessment: SourceAssessment

    public init(
        title: String?,
        uploader: String?,
        durationSeconds: Double?,
        selectedAudio: SelectedSourceAudio,
        assessment: SourceAssessment
    ) {
        self.title = title
        self.uploader = uploader
        self.durationSeconds = durationSeconds
        self.selectedAudio = selectedAudio
        self.assessment = assessment
    }
}
