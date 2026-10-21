import TrackDownloaderCore
import Foundation
import XCTest
@testable import TrackDownloader

@MainActor
final class DownloadedTrackStoreTests: XCTestCase {
    func testLibraryDestinationProvidesStableInlineScopePresentation() {
        XCTAssertEqual(LibraryDestination.allTracks.title, "All Tracks")
        XCTAssertEqual(LibraryDestination.favorites.systemImage, "star")
        XCTAssertTrue(LibraryDestination.needsMetadata.isBuiltIn)
        XCTAssertFalse(LibraryDestination.crate(UUID()).isBuiltIn)
    }

    func testColumnConfigurationHidesAndReordersOptionalColumns() {
        var configuration = CatalogueColumnConfiguration.default

        configuration.toggle(.format)
        configuration.move(.quality, before: .artist)

        XCTAssertEqual(Array(configuration.visibleColumns.prefix(4)), [.artwork, .track, .waveform, .quality])
        XCTAssertFalse(configuration.visibleColumns.contains(.format))
    }

    func testDefaultColumnsPlaceWaveformBesideTrack() {
        XCTAssertEqual(
            CatalogueColumn.defaultVisible,
            [.artwork, .track, .waveform, .artist, .format, .quality, .added]
        )
    }

    func testLegacyColumnConfigurationAddsWaveformOnlyOnce() throws {
        let legacy = Data("{\"visibleColumns\":[\"artwork\",\"track\",\"artist\"]}".utf8)
        var configuration = try JSONDecoder().decode(CatalogueColumnConfiguration.self, from: legacy)

        XCTAssertEqual(configuration.visibleColumns, [.artwork, .track, .waveform, .artist])
        configuration.toggle(.waveform)
        let encoded = try JSONEncoder().encode(configuration)
        let restored = try JSONDecoder().decode(CatalogueColumnConfiguration.self, from: encoded)

        XCTAssertFalse(restored.visibleColumns.contains(.waveform))
    }

    func testOldOrganizationJSONLoadsDefaultColumns() throws {
        let organization = try JSONDecoder().decode(
            LibraryOrganization.self,
            from: Data("{\"favorites\":[],\"crates\":[]}".utf8)
        )

        XCTAssertEqual(organization.catalogueColumns.visibleColumns, CatalogueColumn.defaultVisible)
    }

    func testValidatingFixtureProvidesTheInitialCheckingState() {
        UserDefaults.standard.set("validating", forKey: "TrackDownloaderFixture")
        defer { UserDefaults.standard.removeObject(forKey: "TrackDownloaderFixture") }

        let store = TrackDownloaderFixture.storeFromEnvironment()

        XCTAssertEqual(
            store?.state,
            .running(DownloadProgress(stage: .validating, fractionCompleted: nil, detail: nil))
        )
    }

    func testInputFixturesAreDeterministicAndLocalOnly() {
        XCTAssertEqual(TrackDownloaderFixture.store(named: "idle")?.state, .idle)
        XCTAssertEqual(TrackDownloaderFixture.store(named: "typed")?.link, "https://music.example/track/example")
    }

    func testCollectionFixtureProvidesTracksWithoutDisclosureState() async {
        let store = TrackDownloaderFixture.downloadedTracksStore(
            named: "collection-multiple",
            outputDirectory: URL(fileURLWithPath: "/tmp/track-downloader-fixture-output", isDirectory: true)
        )
        store?.refresh()
        await waitUntil { store?.tracks.count == 3 }
        XCTAssertEqual(store?.tracks.map(\.title), ["Aerial Pattern", "Night Drive", "Recorder Trim"])
    }

    func testScannerIncludesSupportedAudioRecursivelyAndIgnoresOtherFiles() throws {
        let outputDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let nestedDirectory = outputDirectory.appendingPathComponent("youtube/Example Artist", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data().write(to: nestedDirectory.appendingPathComponent("Night Drive.flac"))
        try Data().write(to: outputDirectory.appendingPathComponent("notes.txt"))
        try Data("{}".utf8).write(to: outputDirectory.appendingPathComponent("Night Drive.info.json"))
        try Data().write(to: outputDirectory.appendingPathComponent("cover.jpg"))

        let result = DownloadedTrackScanner().scan(in: outputDirectory)

        XCTAssertTrue(result.isOutputDirectoryAvailable)
        XCTAssertEqual(result.tracks.map(\.fileURL.lastPathComponent), ["Night Drive.flac"])
    }

    func testScannerOrdersTracksNewestFirstWithStablePathTieBreak() throws {
        let outputDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let older = outputDirectory.appendingPathComponent("Older.mp3")
        let newerA = outputDirectory.appendingPathComponent("A-z.wav")
        let newerB = outputDirectory.appendingPathComponent("a-a.wav")
        try Data().write(to: older)
        try Data().write(to: newerB)
        try Data().write(to: newerA)

        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_710_000_000)
        try FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: newerA.path)
        try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: newerB.path)

        let tracks = DownloadedTrackScanner().scan(in: outputDirectory).tracks

        XCTAssertEqual(tracks.map(\.fileURL.lastPathComponent), ["A-z.wav", "a-a.wav", "Older.mp3"])
    }

    func testScannerUsesMatchingSidecarAndFallsBackForMalformedSidecar() throws {
        let outputDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let identified = outputDirectory.appendingPathComponent("identified.opus")
        let malformed = outputDirectory.appendingPathComponent("fallback.aiff")
        try Data().write(to: identified)
        try Data().write(to: malformed)
        try Data("{\"title\": \"Saved Set\", \"artist\": \"DJ Example\"}".utf8)
            .write(to: identified.deletingPathExtension().appendingPathExtension("info.json"))
        try Data("not json".utf8)
            .write(to: malformed.deletingPathExtension().appendingPathExtension("info.json"))

        let tracks = DownloadedTrackScanner().scan(in: outputDirectory).tracks
        let byFilename = Dictionary(uniqueKeysWithValues: tracks.map { ($0.fileURL.lastPathComponent, $0) })

        XCTAssertEqual(byFilename["identified.opus"]?.title, "Saved Set")
        XCTAssertEqual(byFilename["identified.opus"]?.artist, "DJ Example")
        XCTAssertEqual(byFilename["fallback.aiff"]?.title, "fallback")
        XCTAssertNil(byFilename["fallback.aiff"]?.artist)
    }

    func testScannerCapturesFileSizeAndRelativeFolderForLibraryDetails() throws {
        let outputDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let nestedDirectory = outputDirectory.appendingPathComponent("soundcloud/Example Artist", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let audio = nestedDirectory.appendingPathComponent("Night Drive.opus")
        try Data(repeating: 7, count: 512).write(to: audio)

        let track = try XCTUnwrap(DownloadedTrackScanner().scan(in: outputDirectory).tracks.first)

        XCTAssertEqual(track.fileSizeBytes, 512)
        XCTAssertEqual(track.relativeDirectory, "soundcloud/Example Artist")
    }

    func testScannerIgnoresAudioSymlinkedOutsideOutputRoot() throws {
        let outputDirectory = try makeTemporaryDirectory()
        let outsideDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }
        let inside = outputDirectory.appendingPathComponent("inside.mp3")
        let outside = outsideDirectory.appendingPathComponent("outside.mp3")
        let linkedOutside = outputDirectory.appendingPathComponent("linked-outside.mp3")
        try Data().write(to: inside)
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(at: linkedOutside, withDestinationURL: outside)

        let tracks = DownloadedTrackScanner().scan(in: outputDirectory).tracks

        XCTAssertEqual(tracks.map(\.fileURL.lastPathComponent), ["inside.mp3"])
    }

    func testScannerIgnoresSidecarSymlinkedOutsideOutputRoot() throws {
        let outputDirectory = try makeTemporaryDirectory()
        let outsideDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }
        let audio = outputDirectory.appendingPathComponent("inside.mp3")
        let outsideSidecar = outsideDirectory.appendingPathComponent("outside.info.json")
        let linkedSidecar = audio.deletingPathExtension().appendingPathExtension("info.json")
        try Data().write(to: audio)
        try Data("{\"title\": \"Outside Metadata\", \"artist\": \"Outside Artist\"}".utf8)
            .write(to: outsideSidecar)
        try FileManager.default.createSymbolicLink(at: linkedSidecar, withDestinationURL: outsideSidecar)

        let track = try XCTUnwrap(DownloadedTrackScanner().scan(in: outputDirectory).tracks.first)

        XCTAssertEqual(track.title, "inside")
        XCTAssertNil(track.artist)
    }

    func testScannerReportsUnavailableFolderWithoutTracks() {
        let unavailable = URL(fileURLWithPath: "/tmp/track-downloader-missing-\(UUID().uuidString)", isDirectory: true)

        let result = DownloadedTrackScanner().scan(in: unavailable)

        XCTAssertFalse(result.isOutputDirectoryAvailable)
        XCTAssertEqual(result.tracks, [])
    }

    func testStoreRefreshPublishesScannerResultsAndEmptyFolderState() async {
        let fileURL = URL(fileURLWithPath: "/tmp/Artist - Night Drive.mp3")
        let track = DownloadedTrack(
            fileURL: fileURL,
            metadata: TrackMetadata(title: "Night Drive", artist: "Artist"),
            savedAt: .distantPast
        )
        let scanner = StubDownloadedTrackScanner(
            result: DownloadedTrackScanResult(tracks: [track], isOutputDirectoryAvailable: true)
        )
        let store = DownloadedTrackStore(
            outputDirectory: URL(fileURLWithPath: "/tmp/track-downloader-store-tests", isDirectory: true),
            scanner: scanner
        )

        XCTAssertEqual(store.tracks, [])
        store.refresh()
        await waitUntil { store.tracks == [track] && scanner.scanCount == 1 }

        XCTAssertEqual(store.tracks, [track])
        XCTAssertTrue(store.isOutputDirectoryAvailable)
        XCTAssertEqual(scanner.scanCount, 1)
    }

    func testStoreRefreshKeepsAvailableEmptyFolderDistinctFromUnavailableFolder() async {
        let scanner = StubDownloadedTrackScanner(
            result: DownloadedTrackScanResult(tracks: [], isOutputDirectoryAvailable: true)
        )
        let store = DownloadedTrackStore(
            outputDirectory: URL(fileURLWithPath: "/tmp/track-downloader-store-tests", isDirectory: true),
            scanner: scanner
        )

        store.refresh()
        await waitUntil { scanner.scanCount == 1 }

        XCTAssertEqual(store.tracks, [])
        XCTAssertTrue(store.isOutputDirectoryAvailable)
    }

    func testRefreshSelectsScannedFileThroughAnOutputFolderAlias() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output", isDirectory: true)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: output)
        let file = output.appendingPathComponent("Saved.m4a")
        try Data().write(to: file)
        let store = DownloadedTrackStore(
            outputDirectory: output,
            persistence: MemoryLibraryOrganizationPersistence()
        )
        var selection: URL?
        var completed = false

        store.refresh(selecting: alias.appendingPathComponent("Saved.m4a")) { selected in
            XCTAssertFalse(store.isRefreshing)
            XCTAssertEqual(store.tracks.count, 1)
            selection = selected
            completed = true
        }
        await waitUntil { completed }

        XCTAssertEqual(selection, store.tracks.first?.fileURL)
        XCTAssertEqual(selection?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
    }

    func testStoreRefreshCreatesOutputDirectoryBeforeScanning() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scanner = StubDownloadedTrackScanner(
            result: DownloadedTrackScanResult(tracks: [], isOutputDirectoryAvailable: true)
        )
        let store = DownloadedTrackStore(outputDirectory: directory, scanner: scanner)

        store.refresh()
        await waitUntil { scanner.scanCount == 1 }

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testStoreRefreshScansOffMainActor() async {
        let scanner = StubDownloadedTrackScanner(
            result: DownloadedTrackScanResult(tracks: [], isOutputDirectoryAvailable: true)
        )
        let store = DownloadedTrackStore(
            outputDirectory: URL(fileURLWithPath: "/tmp/track-downloader-store-tests", isDirectory: true),
            scanner: scanner
        )

        store.refresh()
        await waitUntil { scanner.scanCount == 1 }

        XCTAssertFalse(scanner.didScanOnMainThread)
    }

    func testLibraryDestinationsSearchAndSortWithoutMovingFiles() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let favorite = libraryTrack(
            filename: "Favorite.opus",
            title: "Zebra Lights",
            artist: "Alpha",
            savedAt: now.addingTimeInterval(-86_400)
        )
        let needsMetadata = libraryTrack(
            filename: "Unknown.wav",
            title: "Amber Room",
            artist: nil,
            savedAt: now.addingTimeInterval(-40 * 86_400)
        )
        let crateTrack = libraryTrack(
            filename: "Crate.flac",
            title: "Night Drive",
            artist: "Beta",
            savedAt: now.addingTimeInterval(-2 * 86_400)
        )
        let crateID = UUID()
        let persistence = MemoryLibraryOrganizationPersistence(
            organization: LibraryOrganization(
                favorites: [favorite.libraryID],
                crates: [TrackCrate(id: crateID, name: "Warm Up", trackIDs: [crateTrack.libraryID])]
            )
        )
        let scanner = StubDownloadedTrackScanner(
            result: DownloadedTrackScanResult(
                tracks: [favorite, needsMetadata, crateTrack],
                isOutputDirectoryAvailable: true
            )
        )
        let store = DownloadedTrackStore(
            outputDirectory: URL(fileURLWithPath: "/tmp/library-tests", isDirectory: true),
            scanner: scanner,
            persistence: persistence
        )

        store.refresh()
        await waitUntil { store.tracks.count == 3 }

        XCTAssertEqual(store.tracks(in: .favorites, matching: "", sortedBy: .title).map(\.title), ["Zebra Lights"])
        XCTAssertEqual(store.tracks(in: .needsMetadata, matching: "", sortedBy: .title).map(\.title), ["Amber Room"])
        XCTAssertEqual(store.tracks(in: .crate(crateID), matching: "", sortedBy: .title).map(\.title), ["Night Drive"])
        XCTAssertEqual(
            store.tracks(in: .recentlyAdded, matching: "", sortedBy: .title, now: now).map(\.title),
            ["Night Drive", "Zebra Lights"]
        )
        XCTAssertEqual(
            store.tracks(in: .allTracks, matching: "beta", sortedBy: .title).map(\.title),
            ["Night Drive"]
        )
        XCTAssertEqual(
            store.tracks(in: .allTracks, matching: "", sortedBy: .artist).map(\.title),
            ["Amber Room", "Zebra Lights", "Night Drive"]
        )
    }

    func testFavoritesAndCratesPersistAsNonDestructiveOrganization() {
        let track = libraryTrack(
            filename: "Night Drive.opus",
            title: "Night Drive",
            artist: "Example Artist",
            savedAt: .distantPast
        )
        let persistence = MemoryLibraryOrganizationPersistence()
        let store = DownloadedTrackStore(
            outputDirectory: URL(fileURLWithPath: "/tmp/library-tests", isDirectory: true),
            persistence: persistence
        )

        store.toggleFavorite(track)
        let crateID = try? XCTUnwrap(store.createCrate(named: "  Opening Set  "))
        if let crateID { store.toggle(track, in: crateID) }

        XCTAssertTrue(store.isFavorite(track))
        XCTAssertEqual(store.crates.map(\.name), ["Opening Set"])
        XCTAssertEqual(persistence.organization.favorites, [track.libraryID])
        XCTAssertEqual(persistence.organization.crates.first?.trackIDs, [track.libraryID])
        XCTAssertEqual(track.fileURL.path, "/tmp/library-tests/Night Drive.opus")
    }

    func testColumnChangesPersistWithoutChangingTracks() {
        let persistence = MemoryLibraryOrganizationPersistence()
        let store = DownloadedTrackStore(
            outputDirectory: URL(fileURLWithPath: "/tmp/library-tests", isDirectory: true),
            persistence: persistence
        )

        store.toggleCatalogueColumn(.source)
        store.moveCatalogueColumn(.source, before: .artist)

        XCTAssertEqual(
            persistence.organization.catalogueColumns.visibleColumns,
            [.artwork, .track, .waveform, .source, .artist, .format, .quality, .added]
        )
        XCTAssertEqual(store.tracks, [])
    }

    func testColumnMoveLaterPersistsTheVisibleOrder() {
        let persistence = MemoryLibraryOrganizationPersistence()
        let store = DownloadedTrackStore(
            outputDirectory: URL(fileURLWithPath: "/tmp/library-tests", isDirectory: true),
            persistence: persistence
        )

        store.moveCatalogueColumn(.format, before: .added)

        XCTAssertEqual(
            persistence.organization.catalogueColumns.visibleColumns,
            [.artwork, .track, .waveform, .artist, .quality, .format, .added]
        )
    }

    func testFailedOrganizationWriteLeavesPublishedStateUnchanged() {
        let track = libraryTrack(
            filename: "Night Drive.opus",
            title: "Night Drive",
            artist: "Example Artist",
            savedAt: .distantPast
        )
        let persistence = MemoryLibraryOrganizationPersistence()
        persistence.saveError = TestOrganizationError.failed
        let store = DownloadedTrackStore(
            outputDirectory: URL(fileURLWithPath: "/tmp/library-tests", isDirectory: true),
            persistence: persistence
        )

        store.toggleFavorite(track)

        XCTAssertFalse(store.isFavorite(track))
        XCTAssertNotNil(store.organizationNotice)
    }

    func testFailedCrateDeletionReturnsFalseAndPreservesCrate() throws {
        let persistence = MemoryLibraryOrganizationPersistence()
        let store = DownloadedTrackStore(
            outputDirectory: URL(fileURLWithPath: "/tmp/library-tests", isDirectory: true),
            persistence: persistence
        )
        let crateID = try XCTUnwrap(store.createCrate(named: "Opening Set"))
        persistence.saveError = TestOrganizationError.failed

        let didDelete = store.deleteCrate(crateID)

        XCTAssertFalse(didDelete)
        XCTAssertEqual(store.crates.map(\.id), [crateID])
        XCTAssertEqual(persistence.organization.crates.map(\.id), [crateID])
        XCTAssertNotNil(store.organizationNotice)
    }

    func testCrateRenameValidationAndDeletionPersist() throws {
        let persistence = MemoryLibraryOrganizationPersistence()
        let store = DownloadedTrackStore(
            outputDirectory: URL(fileURLWithPath: "/tmp/library-tests", isDirectory: true),
            persistence: persistence
        )
        let crateID = try XCTUnwrap(store.createCrate(named: "Warm Up"))

        XCTAssertNil(store.createCrate(named: "  warm up  "))
        store.renameCrate(crateID, to: "  Peak Time  ")
        XCTAssertEqual(persistence.organization.crates.map(\.name), ["Peak Time"])

        store.deleteCrate(crateID)
        XCTAssertTrue(store.crates.isEmpty)
        XCTAssertTrue(persistence.organization.crates.isEmpty)
    }

    func testFileOrganizationPersistenceRoundTripsAtomically() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileLibraryOrganizationPersistence(
            fileURL: directory.appendingPathComponent("Library Organization.json")
        )
        let crate = TrackCrate(name: "Peak Time", trackIDs: ["/music/track.opus"])
        let organization = LibraryOrganization(favorites: ["/music/track.opus"], crates: [crate])

        try persistence.save(organization)

        XCTAssertEqual(try persistence.load(), organization)
    }

    #if DEBUG
    func testDebugCollectionFixturesProvideDeterministicMultipleTrackState() async {
        let outputDirectory = URL(fileURLWithPath: "/tmp/track-downloader-fixture-output", isDirectory: true)
        let store = TrackDownloaderFixture.downloadedTracksStore(named: "collection-multiple", outputDirectory: outputDirectory)

        XCTAssertNotNil(store)
        store?.refresh()
        await waitUntil { store?.tracks.count == 3 }

        XCTAssertEqual(store?.tracks.map(\.title), ["Aerial Pattern", "Night Drive", "Recorder Trim"])
        XCTAssertTrue(store?.isOutputDirectoryAvailable == true)
        XCTAssertEqual(store?.favoriteCount, 1)
        XCTAssertEqual(store?.crates.map(\.name), ["Opening Set"])
        XCTAssertEqual(
            store?.count(in: .recentlyAdded, now: Date(timeIntervalSince1970: 1_723_000_000)),
            2
        )
    }
    #endif

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadedTrackStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func libraryTrack(
        filename: String,
        title: String,
        artist: String?,
        savedAt: Date
    ) -> DownloadedTrack {
        DownloadedTrack(
            fileURL: URL(fileURLWithPath: "/tmp/library-tests/\(filename)"),
            metadata: TrackMetadata(title: title, artist: artist),
            savedAt: savedAt
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

private enum TestOrganizationError: Error {
    case failed
}

private final class StubDownloadedTrackScanner: DownloadedTrackScanning, @unchecked Sendable {
    let result: DownloadedTrackScanResult
    private let lock = NSLock()
    private var recordedScanCount = 0
    private var recordedDidScanOnMainThread = false

    init(result: DownloadedTrackScanResult) {
        self.result = result
    }

    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedScanCount
    }

    var didScanOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordedDidScanOnMainThread
    }

    func scan(in outputDirectory: URL) -> DownloadedTrackScanResult {
        lock.lock()
        recordedScanCount += 1
        recordedDidScanOnMainThread = Thread.isMainThread
        lock.unlock()
        return result
    }
}
