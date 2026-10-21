import AppKit
import TrackDownloaderCore
import Foundation

@MainActor
final class DownloadedTrackStore: ObservableObject {
    @Published private(set) var tracks: [DownloadedTrack] = []
    @Published private(set) var isOutputDirectoryAvailable = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var organization = LibraryOrganization()
    @Published private(set) var organizationNotice: String?

    let outputDirectory: URL
    private let scanner: any DownloadedTrackScanning
    private let persistence: any LibraryOrganizationPersisting
    private var refreshTask: Task<Void, Never>?
    private var activeRefreshID: UUID?

    init(
        outputDirectory: URL,
        scanner: any DownloadedTrackScanning = DownloadedTrackScanner(),
        persistence: any LibraryOrganizationPersisting = FileLibraryOrganizationPersistence.applicationSupport()
    ) {
        self.outputDirectory = outputDirectory
        self.scanner = scanner
        self.persistence = persistence

        do {
            organization = try persistence.load()
        } catch {
            organizationNotice = "Your saved library organization could not be loaded. Tracks are still safe on disk."
        }
    }

    var crates: [TrackCrate] {
        organization.crates.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var favoriteCount: Int {
        tracks.lazy.filter(isFavorite).count
    }

    var needsMetadataCount: Int {
        tracks.lazy.filter(needsMetadata).count
    }

    var visibleCatalogueColumns: [CatalogueColumn] {
        organization.catalogueColumns.visibleColumns
    }

    func refresh() {
        refresh(onCompletion: nil)
    }

    func refresh(selecting fileURL: URL, onSelection: @escaping (URL?) -> Void) {
        let resolvedFileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
        refresh { tracks in
            let track = tracks.first {
                $0.fileURL.resolvingSymlinksInPath().standardizedFileURL == resolvedFileURL
            }
            onSelection(track?.fileURL)
        }
    }

    private func refresh(onCompletion: (([DownloadedTrack]) -> Void)?) {
        try? FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let refreshID = UUID()
        activeRefreshID = refreshID
        refreshTask?.cancel()
        isRefreshing = true

        let scanner = self.scanner
        let outputDirectory = self.outputDirectory
        refreshTask = Task { [weak self, scanner, outputDirectory] in
            let result = await Task.detached(priority: .utility) {
                scanner.scan(in: outputDirectory)
            }.value

            guard !Task.isCancelled,
                  let self,
                  self.activeRefreshID == refreshID else {
                return
            }
            self.tracks = result.tracks
            self.isOutputDirectoryAvailable = result.isOutputDirectoryAvailable
            self.isRefreshing = false
            onCompletion?(result.tracks)
        }
    }

    func tracks(
        in destination: LibraryDestination,
        matching searchText: String,
        sortedBy sort: LibrarySort,
        now: Date = Date()
    ) -> [DownloadedTrack] {
        let scoped = tracks.filter { track in
            switch destination {
            case .download, .allTracks:
                true
            case .recentlyAdded:
                track.savedAt >= Calendar.current.date(byAdding: .day, value: -30, to: now) ?? .distantPast
            case .favorites:
                isFavorite(track)
            case .needsMetadata:
                needsMetadata(track)
            case .crate(let crateID):
                organization.crates.first(where: { $0.id == crateID })?.trackIDs.contains(track.libraryID) == true
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? scoped : scoped.filter { track in
            [track.title, track.artist, track.album, track.genre, track.relativeDirectory, track.fileURL.lastPathComponent]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }

        return filtered.sorted { lhs, rhs in
            switch sort {
            case .recentlyAdded:
                if lhs.savedAt != rhs.savedAt { return lhs.savedAt > rhs.savedAt }
            case .title:
                let result = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if result != .orderedSame { return result == .orderedAscending }
            case .artist:
                let lhsArtist = lhs.artist ?? ""
                let result = lhsArtist.localizedCaseInsensitiveCompare(rhs.artist ?? "")
                if result != .orderedSame { return result == .orderedAscending }
            case .format:
                let result = lhs.format.localizedCaseInsensitiveCompare(rhs.format)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return lhs.fileURL.path.localizedCaseInsensitiveCompare(rhs.fileURL.path) == .orderedAscending
        }
    }

    func count(in destination: LibraryDestination, now: Date = Date()) -> Int {
        tracks(in: destination, matching: "", sortedBy: .recentlyAdded, now: now).count
    }

    func isFavorite(_ track: DownloadedTrack) -> Bool {
        organization.favorites.contains(track.libraryID)
    }

    func toggleFavorite(_ track: DownloadedTrack) {
        commit { draft in
            if draft.favorites.remove(track.libraryID) == nil {
                draft.favorites.insert(track.libraryID)
            }
        }
    }

    func toggleCatalogueColumn(_ column: CatalogueColumn) {
        commit { draft in
            draft.catalogueColumns.toggle(column)
        }
    }

    func moveCatalogueColumn(_ column: CatalogueColumn, before destination: CatalogueColumn) {
        commit { draft in
            draft.catalogueColumns.move(column, before: destination)
        }
    }

    @discardableResult
    func createCrate(named proposedName: String) -> UUID? {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !organization.crates.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }

        let crate = TrackCrate(name: name)
        return commit({ $0.crates.append(crate) }) ? crate.id : nil
    }

    func renameCrate(_ crateID: UUID, to proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !organization.crates.contains(where: {
                $0.id != crateID && $0.name.caseInsensitiveCompare(name) == .orderedSame
              }) else { return }

        commit { draft in
            guard let index = draft.crates.firstIndex(where: { $0.id == crateID }) else { return }
            draft.crates[index].name = name
        }
    }

    @discardableResult
    func deleteCrate(_ crateID: UUID) -> Bool {
        commit { draft in
            draft.crates.removeAll { $0.id == crateID }
        }
    }

    func contains(_ track: DownloadedTrack, in crate: TrackCrate) -> Bool {
        crate.trackIDs.contains(track.libraryID)
    }

    func toggle(_ track: DownloadedTrack, in crateID: UUID) {
        commit { draft in
            guard let index = draft.crates.firstIndex(where: { $0.id == crateID }) else { return }
            if draft.crates[index].trackIDs.remove(track.libraryID) == nil {
                draft.crates[index].trackIDs.insert(track.libraryID)
            }
        }
    }

    func dismissOrganizationNotice() {
        organizationNotice = nil
    }

    func reveal(_ track: DownloadedTrack) {
        NSWorkspace.shared.activateFileViewerSelecting([track.fileURL])
    }

    func openOutputDirectory() {
        NSWorkspace.shared.open(outputDirectory)
    }

    private func needsMetadata(_ track: DownloadedTrack) -> Bool {
        track.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    @discardableResult
    private func commit(_ change: (inout LibraryOrganization) -> Void) -> Bool {
        var draft = organization
        change(&draft)
        guard draft != organization else { return true }

        do {
            try persistence.save(draft)
            organization = draft
            organizationNotice = nil
            return true
        } catch {
            organizationNotice = "That library change could not be saved. No audio files were changed."
            return false
        }
    }
}
