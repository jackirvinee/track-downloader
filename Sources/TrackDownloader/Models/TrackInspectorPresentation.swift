import Foundation
import TrackDownloaderCore

enum TrackInspectorField: String, CaseIterable, Identifiable {
    case path, format, added, fileSize, album, genre, source
    case quality, duration, codec, bitrate, sampleRate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .path: "Path"
        case .format: "Format"
        case .added: "Added"
        case .fileSize: "File Size"
        case .album: "Album"
        case .genre: "Genre"
        case .source: "Source"
        case .quality: "Quality"
        case .duration: "Duration"
        case .codec: "Codec"
        case .bitrate: "Bitrate"
        case .sampleRate: "Sample Rate"
        }
    }

    var isTechnical: Bool {
        self == .path || self == .format || self == .codec || self == .bitrate || self == .sampleRate
    }
}

struct TrackInspectorFact: Equatable, Identifiable {
    let field: TrackInspectorField
    let value: String
    var id: String { field.rawValue }
}

struct TrackInspectorPresentation: Equatable {
    let title: String
    let artist: String
    let facts: [TrackInspectorFact]

    init(track: DownloadedTrack) {
        title = track.title
        artist = Self.nonEmpty(track.artist) ?? "—"
        facts = TrackInspectorField.allCases.map { field in
            TrackInspectorFact(field: field, value: Self.value(for: field, track: track))
        }
    }

    func value(for field: TrackInspectorField) -> String {
        facts.first(where: { $0.field == field })?.value ?? "—"
    }

    private static func value(for field: TrackInspectorField, track: DownloadedTrack) -> String {
        switch field {
        case .path: track.fileURL.path
        case .format: track.format.isEmpty ? "—" : track.format
        case .added: track.savedAt.formatted(date: .abbreviated, time: .shortened)
        case .fileSize: track.fileSizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        case .album: nonEmpty(track.album) ?? "—"
        case .genre: nonEmpty(track.genre) ?? "—"
        case .source: nonEmpty(track.relativeDirectory) ?? "—"
        case .quality, .duration, .codec, .bitrate, .sampleRate: "—"
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
