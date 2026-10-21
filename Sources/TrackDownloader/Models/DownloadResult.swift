import TrackDownloaderCore
import Foundation

struct DownloadResult: Equatable {
    let fileURL: URL
    let metadata: TrackMetadata
    let quality: AudioQuality
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
