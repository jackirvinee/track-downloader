import TrackDownloaderCore

enum SourcePreflightState: Equatable {
    case idle
    case checking
    case ready(SourcePreflightResult)
    case unavailable(String)
    case invalidLink(String)
}
