import Foundation

/// What loads on every Pioneer/AlphaTheta deck a DJ is likely to meet: CDJ-900NXS, CDJ-2000,
/// CDJ-2000NXS/NXS2, CDJ-3000, XDJ-RX/XZ and Opus Quad. The rules are the strictest common
/// denominator, so a file that passes them needs no per-deck re-export.
///
/// - MP3 at 32, 44.1 or 48 kHz. 16–24 kHz (MPEG-2) MP3 is only a warning.
/// - AAC-LC in .m4a/.mp4. HE-AAC fails on older decks.
/// - WAV/AIFF holding 16- or 24-bit integer PCM at 44.1 or 48 kHz.
/// - At most two channels.
/// - No FLAC or ALAC (NXS2/3000 only) and no Opus or Vorbis (no deck).
/// - The extension must match the codec: decks pick the decoder from the extension.
///
/// Every check runs on what ffprobe reports for the real file, never on the extension alone.
public enum CDJFormatRules {
    public static let universalPCMRates: Set<Int> = [44_100, 48_000]
    public static let mp3Rates: Set<Int> = [32_000, 44_100, 48_000]
    public static let mp3LowRates: Set<Int> = [16_000, 22_050, 24_000]
    public static let aacRates: Set<Int> = [16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
    public static let pcmBits: [String: Int] = [
        "pcm_s16le": 16, "pcm_s24le": 24, "pcm_s16be": 16, "pcm_s24be": 24,
        "pcm_s32le": 32, "pcm_s32be": 32, "pcm_f32le": 32, "pcm_f32be": 32,
        "pcm_f64le": 64, "pcm_f64be": 64, "pcm_u8": 8, "pcm_s8": 8
    ]
    /// Codecs each extension may hold. Anything else (.flac, .opus, .ogg, .webm, ...) is unsupported.
    public static let extensionCodecs: [String: Set<String>] = [
        "mp3": ["mp3"],
        "m4a": ["aac"],
        "mp4": ["aac"],
        "wav": Set(pcmBits.keys),
        "aif": Set(pcmBits.keys),
        "aiff": Set(pcmBits.keys)
    ]
    /// Characters a FAT32 USB can't store in a file name.
    public static let fat32ForbiddenCharacters = CharacterSet(charactersIn: "\\:*?\"<>|")

    public static func issues(for probe: CDJAudioProbe?, fileExtension: String) -> [CDJIssue] {
        guard let probe else { return [CDJIssue(.unreadable)] }
        guard let codec = probe.codec else {
            return [probe.hasVideo ? CDJIssue(.notAudio) : CDJIssue(.unreadable, "no audio stream")]
        }
        let ext = fileExtension.lowercased()
        let rate = probe.sampleRateHz
        var issues: [CDJIssue] = []

        if let expected = extensionCodecs[ext] {
            if !expected.contains(codec) {
                issues.append(codec == "alac"
                    ? CDJIssue(.unsupportedFormat, "ALAC")
                    : CDJIssue(.extensionMismatch, "\(codec) in .\(ext)"))
            }
        } else {
            issues.append(CDJIssue(.unsupportedFormat, ext.isEmpty ? codec : ".\(ext)"))
        }

        if let bits = pcmBits[codec] {
            if bits != 16 && bits != 24 {
                issues.append(CDJIssue(.bitDepth, "\(bits)-bit\(codec.contains("_f") ? " float" : "")"))
            }
            if !universalPCMRates.contains(rate) {
                issues.append(CDJIssue(.sampleRate, kilohertz(rate)))
            }
        } else if codec == "mp3" {
            if mp3LowRates.contains(rate) {
                issues.append(CDJIssue(.mp3LowRate, kilohertz(rate)))
            } else if !mp3Rates.contains(rate) {
                issues.append(CDJIssue(.sampleRate, kilohertz(rate)))
            }
        } else if codec == "aac" {
            if let profile = probe.profile, profile.contains("HE") {
                issues.append(CDJIssue(.aacProfile, profile))
            }
            if !aacRates.contains(rate) {
                issues.append(CDJIssue(.sampleRate, kilohertz(rate)))
            }
        }

        if probe.channels > 2 {
            issues.append(CDJIssue(.unsupportedFormat, "\(probe.channels) channels"))
        }
        return issues
    }

    public static func fileNameIssue(_ fileName: String) -> CDJIssue? {
        fileName.rangeOfCharacter(from: fat32ForbiddenCharacters) == nil ? nil : CDJIssue(.fat32Name)
    }

    /// Whether a source stream yt-dlp reports (its `acodec`, e.g. `mp4a.40.2`) plays on every deck
    /// as downloaded, before any conversion.
    public static func isUniversallyPlayable(sourceCodec: String, sampleRateHz: Int?) -> Bool {
        let codec = sourceCodec.lowercased()
        func rateAllowed(_ rates: Set<Int>) -> Bool { sampleRateHz.map(rates.contains) ?? true }
        if codec == "mp3" { return rateAllowed(mp3Rates.union(mp3LowRates)) }
        if ["aac", "mp4a", "mp4a.40.2"].contains(codec) { return rateAllowed(aacRates) }
        if let bits = pcmBits[codec] { return (bits == 16 || bits == 24) && rateAllowed(universalPCMRates) }
        return false
    }

    static func kilohertz(_ hertz: Int) -> String {
        let khz = Double(hertz) / 1_000
        return khz.rounded() == khz ? "\(Int(khz)) kHz" : String(format: "%g kHz", khz)
    }
}

public struct CDJIssue: Equatable, Sendable {
    public enum Code: String, Sendable {
        case unreadable, notAudio, extensionMismatch, unsupportedFormat
        case bitDepth, sampleRate, aacProfile, mp3LowRate, fat32Name
    }

    public enum Severity: String, Sendable {
        case error, warning, info
    }

    public let code: Code
    public let detail: String

    public init(_ code: Code, _ detail: String = "") {
        self.code = code
        self.detail = detail
    }

    public var severity: Severity {
        switch code {
        case .mp3LowRate: .warning
        case .fat32Name: .info
        default: .error
        }
    }

    public var title: String {
        switch code {
        case .unreadable: "Broken or not a real audio file"
        case .notAudio: "No audio stream (video file)"
        case .extensionMismatch: "Extension doesn't match the format"
        case .unsupportedFormat: "Format not supported on all decks"
        case .bitDepth: "Bit depth CDJs can't play"
        case .sampleRate: "Sample rate not supported"
        case .aacProfile: "HE-AAC (older decks can't decode)"
        case .mp3LowRate: "Low sample-rate MP3"
        case .fat32Name: "Characters FAT32 doesn't allow"
        }
    }

    public var summary: String {
        detail.isEmpty ? title : "\(title) (\(detail))"
    }
}

/// The parts of `ffprobe -show_format -show_streams -of json` the CDJ rules need.
public struct CDJAudioProbe: Equatable, Sendable {
    public let codec: String?
    public let profile: String?
    public let sampleRateHz: Int
    public let channels: Int
    public let bitsPerRawSample: Int?
    public let durationSeconds: Double?
    public let hasVideo: Bool
    /// Ogg/Opus keep their tags on the audio stream rather than the container.
    public let tagsAreOnAudioStream: Bool

    public init(
        codec: String?,
        profile: String? = nil,
        sampleRateHz: Int = 0,
        channels: Int = 2,
        bitsPerRawSample: Int? = nil,
        durationSeconds: Double? = nil,
        hasVideo: Bool = false,
        tagsAreOnAudioStream: Bool = false
    ) {
        self.codec = codec
        self.profile = profile
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.bitsPerRawSample = bitsPerRawSample
        self.durationSeconds = durationSeconds
        self.hasVideo = hasVideo
        self.tagsAreOnAudioStream = tagsAreOnAudioStream
    }

    /// Returns nil when ffprobe couldn't read a container at all.
    public static func parse(ffprobeJSON data: Data) -> CDJAudioProbe? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let format = payload.format
        else { return nil }
        let streams = payload.streams ?? []
        let audio = streams.first { $0.codecType == "audio" }
        let hasVideo = streams.contains { $0.codecType == "video" && $0.disposition?.attachedPic != 1 }
        let containerTagged = format.tags.map(Self.hasTrackTags) ?? false
        let streamTagged = audio?.tags.map(Self.hasTrackTags) ?? false

        return CDJAudioProbe(
            codec: audio?.codecName,
            profile: audio?.profile,
            sampleRateHz: audio?.sampleRate.flatMap(Int.init) ?? 0,
            channels: audio?.channels ?? 0,
            bitsPerRawSample: audio?.bitsPerRawSample.flatMap(Int.init),
            durationSeconds: format.duration.flatMap(Double.init),
            hasVideo: hasVideo,
            tagsAreOnAudioStream: streamTagged && !containerTagged
        )
    }

    private static func hasTrackTags(_ tags: [String: String]) -> Bool {
        tags.keys.contains { ["title", "artist"].contains($0.lowercased()) }
    }

    private struct Payload: Decodable {
        let streams: [Stream]?
        let format: Format?
    }

    private struct Stream: Decodable {
        let codecType: String?
        let codecName: String?
        let profile: String?
        let sampleRate: String?
        let channels: Int?
        let bitsPerRawSample: String?
        let disposition: Disposition?
        let tags: [String: String]?

        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type"
            case codecName = "codec_name"
            case profile
            case sampleRate = "sample_rate"
            case channels
            case bitsPerRawSample = "bits_per_raw_sample"
            case disposition
            case tags
        }
    }

    private struct Disposition: Decodable {
        let attachedPic: Int?

        enum CodingKeys: String, CodingKey {
            case attachedPic = "attached_pic"
        }
    }

    private struct Format: Decodable {
        let duration: String?
        let tags: [String: String]?
    }
}

/// How to turn a downloaded file into one every deck loads, without touching files that already do.
///
/// - AAC or MP3 in the wrong container is remuxed (no re-encode).
/// - Everything else that fails (FLAC, ALAC, Opus, HE-AAC, 32-bit or 8-bit PCM, odd sample
///   rates, surround) becomes WAV: 24-bit, or 16-bit when the source is 16-bit or lossy, at
///   44.1 or 48 kHz, downmixed to stereo when needed.
public enum CDJSafeAction: Equatable, Sendable {
    case keep
    case remux(fileExtension: String)
    case convertToWAV(bitDepth: Int, sampleRateHz: Int, downmixToStereo: Bool)
    case cannotFix(String)

    public static func plan(for probe: CDJAudioProbe?, fileExtension: String) -> CDJSafeAction {
        let issues = CDJFormatRules.issues(for: probe, fileExtension: fileExtension)
        let errors = issues.filter { $0.severity == .error }
        guard !errors.isEmpty else { return .keep }
        guard let probe, let codec = probe.codec else {
            return .cannotFix(errors.map(\.summary).joined(separator: "; "))
        }

        let heAAC = probe.profile?.contains("HE") ?? false
        if errors.allSatisfy({ $0.code == .extensionMismatch }), codec == "aac" || codec == "mp3", !heAAC {
            return .remux(fileExtension: codec == "aac" ? "m4a" : "mp3")
        }

        let sourceBits = CDJFormatRules.pcmBits[codec]
            ?? (["flac", "alac"].contains(codec) ? probe.bitsPerRawSample ?? 24 : 16)
        return .convertToWAV(
            bitDepth: sourceBits <= 16 ? 16 : 24,
            sampleRateHz: targetSampleRate(probe.sampleRateHz),
            downmixToStereo: probe.channels > 2
        )
    }

    /// 44.1 and 48 kHz stay; multiples of 48 kHz go to 48 kHz; everything else to 44.1 kHz.
    public static func targetSampleRate(_ hertz: Int) -> Int {
        if CDJFormatRules.universalPCMRates.contains(hertz) { return hertz }
        return hertz > 48_000 && hertz % 48_000 == 0 ? 48_000 : 44_100
    }

    public var targetExtension: String? {
        switch self {
        case let .remux(fileExtension): fileExtension
        case .convertToWAV: "wav"
        case .keep, .cannotFix: nil
        }
    }

    public var summary: String {
        switch self {
        case .keep: "already plays on every deck"
        case let .remux(fileExtension): "rewrapped as .\(fileExtension) (audio untouched)"
        case let .convertToWAV(bitDepth, sampleRateHz, downmix):
            "converted to \(bitDepth)-bit WAV, \(CDJFormatRules.kilohertz(sampleRateHz))\(downmix ? ", stereo" : "")"
        case let .cannotFix(reason): reason
        }
    }

    /// ffmpeg arguments that write the CDJ-safe copy. `-n` never overwrites an existing file.
    public func ffmpegArguments(input: String, output: String, probe: CDJAudioProbe) -> [String] {
        let base = [
            "-nostdin", "-v", "error", "-n",
            "-i", input,
            "-map", "0:a:0",
            "-map_metadata", probe.tagsAreOnAudioStream ? "0:s:a:0" : "0"
        ]
        switch self {
        case let .remux(fileExtension):
            // moov first, like the AAC files every deck already loads.
            return base + ["-c:a", "copy"] + (fileExtension == "m4a" ? ["-movflags", "+faststart"] : []) + [output]
        case let .convertToWAV(bitDepth, sampleRateHz, downmix):
            return base
                + ["-c:a", bitDepth == 16 ? "pcm_s16le" : "pcm_s24le", "-ar", String(sampleRateHz)]
                + (downmix ? ["-ac", "2"] : [])
                + [output]
        case .keep, .cannotFix:
            return []
        }
    }

    /// Why a converted copy must not replace the download, or nil when it's good: it has to be
    /// readable, pass every CDJ error rule, and keep the source's length (within 0.2 s, or 1% when
    /// the source length is only an estimate, as with raw ADTS AAC).
    public static func verificationProblem(
        source: CDJAudioProbe,
        converted: CDJAudioProbe?,
        fileExtension: String
    ) -> String? {
        guard let converted, converted.codec != nil else { return "the converted file is unreadable" }
        if let failure = CDJFormatRules.issues(for: converted, fileExtension: fileExtension)
            .first(where: { $0.severity == .error }) {
            return "the converted file still fails: \(failure.summary)"
        }
        if let before = source.durationSeconds, let after = converted.durationSeconds,
           abs(before - after) > max(0.2, before * 0.01) {
            return String(format: "the length changed (%.2fs to %.2fs)", before, after)
        }
        return nil
    }
}
