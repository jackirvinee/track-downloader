import Foundation

public struct DownloadedTrack: Equatable, Identifiable, Sendable {
    public let fileURL: URL
    public let title: String
    public let artist: String?
    public let album: String?
    public let genre: String?
    public let format: String
    public let savedAt: Date
    public let fileSizeBytes: Int64?
    public let relativeDirectory: String?

    public var id: URL { fileURL }
    public var libraryID: String { fileURL.standardizedFileURL.path }

    public init(
        fileURL: URL,
        metadata: TrackMetadata?,
        savedAt: Date,
        fileSizeBytes: Int64? = nil,
        relativeDirectory: String? = nil
    ) {
        self.fileURL = fileURL
        self.title = metadata?.title ?? fileURL.deletingPathExtension().lastPathComponent
        self.artist = metadata?.artist
        self.album = metadata?.album
        self.genre = metadata?.genre
        self.format = fileURL.pathExtension.uppercased()
        self.savedAt = savedAt
        self.fileSizeBytes = fileSizeBytes
        self.relativeDirectory = relativeDirectory
    }
}
