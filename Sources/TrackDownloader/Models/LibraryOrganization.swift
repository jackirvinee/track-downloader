import Foundation

enum CatalogueColumn: String, CaseIterable, Codable, Equatable, Identifiable {
    case artwork
    case track
    case waveform
    case artist
    case format
    case quality
    case added
    case album
    case genre
    case source
    case duration
    case codec
    case bitrate
    case sampleRate
    case fileSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .artwork: "Artwork"
        case .track: "Track"
        case .waveform: "Waveform"
        case .artist: "Artist"
        case .format: "Format"
        case .quality: "Quality"
        case .added: "Added"
        case .album: "Album"
        case .genre: "Genre"
        case .source: "Source"
        case .duration: "Duration"
        case .codec: "Codec"
        case .bitrate: "Bitrate"
        case .sampleRate: "Sample Rate"
        case .fileSize: "File Size"
        }
    }

    static let defaultVisible: [CatalogueColumn] = [.artwork, .track, .waveform, .artist, .format, .quality, .added]
}

struct CatalogueColumnConfiguration: Codable, Equatable {
    private(set) var visibleColumns: [CatalogueColumn]
    private var hasSeenWaveformColumn: Bool

    static let `default` = CatalogueColumnConfiguration(visibleColumns: CatalogueColumn.defaultVisible)

    init(
        visibleColumns: [CatalogueColumn] = CatalogueColumn.defaultVisible,
        hasSeenWaveformColumn: Bool = true
    ) {
        self.visibleColumns = Self.normalized(visibleColumns)
        self.hasSeenWaveformColumn = hasSeenWaveformColumn
    }

    private enum CodingKeys: String, CodingKey {
        case visibleColumns
        case hasSeenWaveformColumn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let savedColumns = try container.decodeIfPresent([CatalogueColumn].self, forKey: .visibleColumns)
            ?? CatalogueColumn.defaultVisible
        let hasSeenWaveformColumn = try container.decodeIfPresent(Bool.self, forKey: .hasSeenWaveformColumn) ?? false
        self.visibleColumns = hasSeenWaveformColumn
            ? Self.normalized(savedColumns)
            : Self.insertingWaveform(into: Self.normalized(savedColumns))
        self.hasSeenWaveformColumn = true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(visibleColumns, forKey: .visibleColumns)
        try container.encode(hasSeenWaveformColumn, forKey: .hasSeenWaveformColumn)
    }

    mutating func toggle(_ column: CatalogueColumn) {
        if let index = visibleColumns.firstIndex(of: column) {
            visibleColumns.remove(at: index)
        } else {
            visibleColumns.append(column)
            visibleColumns = Self.normalized(visibleColumns)
        }
    }

    mutating func move(_ column: CatalogueColumn, before destination: CatalogueColumn) {
        guard let sourceIndex = visibleColumns.firstIndex(of: column),
              let destinationIndex = visibleColumns.firstIndex(of: destination),
              sourceIndex != destinationIndex else { return }
        visibleColumns.remove(at: sourceIndex)
        let adjustedDestination = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        visibleColumns.insert(column, at: adjustedDestination)
    }

    private static func normalized(_ columns: [CatalogueColumn]) -> [CatalogueColumn] {
        var seen = Set<CatalogueColumn>()
        return columns.filter { seen.insert($0).inserted }
    }

    private static func insertingWaveform(into columns: [CatalogueColumn]) -> [CatalogueColumn] {
        guard !columns.contains(.waveform) else { return columns }
        guard let trackIndex = columns.firstIndex(of: .track) else { return [.waveform] + columns }
        var result = columns
        result.insert(.waveform, at: result.index(after: trackIndex))
        return result
    }
}

enum LibraryDestination: Hashable {
    case download
    case allTracks
    case recentlyAdded
    case favorites
    case needsMetadata
    case crate(UUID)

    var title: String {
        switch self {
        case .download: "Download"
        case .allTracks: "All Tracks"
        case .recentlyAdded: "Recently Added"
        case .favorites: "Favorites"
        case .needsMetadata: "Needs Metadata"
        case .crate: "Crate"
        }
    }

    var systemImage: String {
        switch self {
        case .download: "arrow.down.circle"
        case .allTracks: "music.note.list"
        case .recentlyAdded: "clock"
        case .favorites: "star"
        case .needsMetadata: "exclamationmark.circle"
        case .crate: "shippingbox"
        }
    }

    var isBuiltIn: Bool {
        if case .crate = self { return false }
        return self != .download
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recentlyAdded
    case title
    case artist
    case format

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .title: "Title"
        case .artist: "Artist"
        case .format: "File Format"
        }
    }
}

struct TrackCrate: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    var trackIDs: Set<String>

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), trackIDs: Set<String> = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.trackIDs = trackIDs
    }
}

struct LibraryOrganization: Codable, Equatable {
    var favorites: Set<String>
    var crates: [TrackCrate]
    var catalogueColumns: CatalogueColumnConfiguration

    init(
        favorites: Set<String> = [],
        crates: [TrackCrate] = [],
        catalogueColumns: CatalogueColumnConfiguration = .default
    ) {
        self.favorites = favorites
        self.crates = crates
        self.catalogueColumns = catalogueColumns
    }

    private enum CodingKeys: String, CodingKey {
        case favorites
        case crates
        case catalogueColumns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favorites = try container.decodeIfPresent(Set<String>.self, forKey: .favorites) ?? []
        crates = try container.decodeIfPresent([TrackCrate].self, forKey: .crates) ?? []
        catalogueColumns = try container.decodeIfPresent(CatalogueColumnConfiguration.self, forKey: .catalogueColumns) ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(favorites, forKey: .favorites)
        try container.encode(crates, forKey: .crates)
        try container.encode(catalogueColumns, forKey: .catalogueColumns)
    }
}
