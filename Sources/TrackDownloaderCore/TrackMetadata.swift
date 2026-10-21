import Foundation

public struct TrackMetadata: Equatable, Sendable {
    public let title: String
    public let artist: String?
    public let album: String?
    public let genre: String?
    public let artworkURL: URL?

    public init(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        artworkURL: URL? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.artworkURL = artworkURL
    }

    public static func decode(from data: Data) -> TrackMetadata? {
        guard let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
              let title = nonEmpty(sidecar.title) else {
            return nil
        }

        return TrackMetadata(
            title: title,
            artist: nonEmpty(sidecar.artist) ?? nonEmpty(sidecar.uploader),
            album: nonEmpty(sidecar.album),
            genre: nonEmpty(sidecar.genre),
            artworkURL: nonEmpty(sidecar.thumbnail).flatMap(URL.init(string:))
        )
    }

    private struct Sidecar: Decodable {
        let title: String?
        let artist: String?
        let uploader: String?
        let album: String?
        let genre: String?
        let thumbnail: String?
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
