import Foundation

struct UpdateRelease: Equatable, Sendable {
    let version: StableVersion
    let notes: String
    let pageURL: URL
}

enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case updateAvailable(UpdateRelease)
}

enum UpdateCheckError: Error, Equatable, Sendable {
    case invalidInstalledVersion
    case noPublicRelease
    case rateLimited
    case invalidResponse
    case networkUnavailable
}
