enum EngineToolID: CaseIterable, Equatable, Sendable {
    case ytDLP
    case ffmpeg
    case ffprobe
    case deno

    var executableName: String {
        switch self {
        case .ytDLP: "yt-dlp"
        case .ffmpeg: "ffmpeg"
        case .ffprobe: "ffprobe"
        case .deno: "deno"
        }
    }

    var versionArguments: [String] {
        switch self {
        case .ffmpeg, .ffprobe: ["-version"]
        case .ytDLP, .deno: ["--version"]
        }
    }

    var missingRecoveryCommand: String {
        switch self {
        case .ytDLP: "brew install yt-dlp"
        case .ffmpeg, .ffprobe: "brew install ffmpeg"
        case .deno: "brew install deno"
        }
    }

    var unrecognizedVersionRecoveryCommand: String {
        switch self {
        case .ytDLP: "brew upgrade yt-dlp"
        case .ffmpeg, .ffprobe: "brew upgrade ffmpeg"
        case .deno: "brew upgrade deno"
        }
    }
}

enum EngineToolStatus: Equatable, Sendable {
    case available(version: String)
    case unavailable
    case versionUnrecognized
}

struct EngineToolHealth: Equatable, Sendable {
    let id: EngineToolID
    let status: EngineToolStatus
    let recoveryCommand: String?
}

struct EngineHealthSnapshot: Equatable, Sendable {
    let tools: [EngineToolHealth]
    let ejsEnabled: Bool
}

enum EngineHealthState: Equatable {
    case idle
    case checking
    case ready(EngineHealthSnapshot)
}
