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

        // FLAC/ALAC are not directly compatible: only the NXS2/3000 read them, so they get
        // converted to WAV after download.
        return CDJFormatRules.isUniversallyPlayable(sourceCodec: codec, sampleRateHz: audio.sampleRateHz)
            ? .readyToDownload
            : .compatibleExportLikely
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
