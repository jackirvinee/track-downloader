import TrackDownloaderCore
import Foundation

struct DownloadResult: Equatable {
    let fileURL: URL
    let metadata: TrackMetadata
    /// Measured on the file as downloaded, before any CDJ-safe conversion, so a lossy source
    /// converted to WAV still reports its real quality.
    let quality: AudioQuality
    var cdjSafety: CDJSafeOutcome? = nil
}

enum CDJSafeOutcome: Equatable {
    case alreadySafe
    case converted(CDJSafeAction)
    case leftAsDownloaded(reason: String)

    var reportSuffix: String {
        switch self {
        case .alreadySafe: " | CDJ-safe"
        case let .converted(action): " | CDJ-safe: \(action.summary)"
        case let .leftAsDownloaded(reason): " | not CDJ-safe: \(reason)"
        }
    }
}

enum DownloadFailureKind: Equatable {
    case unsupportedURL
    case missingDependency(name: String, installCommand: String)
    case extractor
    case alreadyInCollection
    case outputFileMissing
    case qualityUnavailable
    case cancelled
    case unexpected
}

struct DownloadFailurePresentation: Error, LocalizedError, Equatable {
    let kind: DownloadFailureKind
    let title: String
    let message: String
    let technicalDetails: String?

    var errorDescription: String? {
        message
    }
}

enum DownloadState: Equatable {
    case idle
    case invalidInput(String)
    case running(DownloadProgress)
    case finished(DownloadResult)
    case failed(DownloadFailurePresentation)
    case cancelled
}
