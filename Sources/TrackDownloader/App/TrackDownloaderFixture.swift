#if DEBUG
import TrackDownloaderCore
import Foundation
import SwiftUI

/// Deterministic local-only states for manual UI checks. This is compiled out of release builds.
@MainActor
enum TrackDownloaderFixture {
    static func preflightStoreFromEnvironment() -> SourcePreflightStore? {
        guard let name = fixtureName()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        switch name {
        case "preflight-ready", "downloading", "downloading-zero", "downloading-complete":
            return SourcePreflightStore(fixtureState: .ready(SourcePreflightResult(title: "Night Drive", uploader: "Example Artist", durationSeconds: 245, selectedAudio: SelectedSourceAudio(codec: "opus", bitrateKbps: 192, sampleRateHz: 48_000), assessment: .compatibleExportLikely)))
        case "preflight-unavailable": return SourcePreflightStore(fixtureState: .unavailable("This source could not be checked right now."))
        default: return nil
        }
    }
    static func storeFromEnvironment() -> DownloadStore? {
        guard let name = fixtureName()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !name.isEmpty else {
            return nil
        }

        return store(named: name)
    }

    static func store(named name: String) -> DownloadStore? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedName.isEmpty else { return nil }

        let outputDirectory = URL(fileURLWithPath: "/tmp/track-downloader-fixture-output", isDirectory: true)
        let state: DownloadState

        switch normalizedName {
        case "idle", "focused", "typed":
            state = .idle
        case "validating":
            state = .running(DownloadProgress(stage: .validating, fractionCompleted: nil, detail: nil))
        case "invalid":
            state = .invalidInput("This app supports YouTube and SoundCloud links.")
        case "downloading":
            state = .running(
                DownloadProgress(
                    stage: .downloading,
                    fractionCompleted: 0.68,
                    detail: "4.8 MiB/s · about 00:08 remaining"
                )
            )
        case "downloading-zero":
            state = .running(
                DownloadProgress(stage: .downloading, fractionCompleted: 0, detail: "Starting transfer.")
            )
        case "downloading-complete":
            state = .running(
                DownloadProgress(stage: .downloading, fractionCompleted: 1, detail: "Finalizing transfer.")
            )
        case "resolving":
            state = .running(DownloadProgress(stage: .resolving, fractionCompleted: nil, detail: nil))
        case "processing":
            state = .running(DownloadProgress(stage: .processing, fractionCompleted: nil, detail: nil))
        case "measuring":
            state = .running(DownloadProgress(stage: .measuringQuality, fractionCompleted: nil, detail: nil))
        case "success-good":
            state = .finished(result(kbps: 256, codec: "opus", sampleRate: 48_000, verdict: .excellent))
        case "success-long-title":
            state = .finished(
                result(
                    kbps: 192,
                    codec: "aac",
                    sampleRate: 44_100,
                    verdict: .good,
                    metadata: TrackMetadata(
                        title: "A Genuinely Long Track Title That Exercises Two Lines Without Secondary Metadata",
                        artist: nil,
                        album: nil,
                        genre: nil
                    )
                )
            )
        case "success-limited":
            state = .finished(result(kbps: 96, codec: "aac", sampleRate: 44_100, verdict: .low))
        case "success-unknown":
            state = .finished(result(kbps: nil, codec: "unknown", sampleRate: nil, verdict: .unknown))
        case "missing-dependency":
            state = .failed(
                DownloadFailurePresentation(
                    kind: .missingDependency(name: "yt-dlp", installCommand: "brew install yt-dlp ffmpeg"),
                    title: "Missing yt-dlp",
                    message: "Install it with Homebrew, then check again.",
                    technicalDetails: "brew install yt-dlp ffmpeg"
                )
            )
        case "already-saved":
            state = .failed(
                DownloadFailurePresentation(
                    kind: .alreadyInCollection,
                    title: "Previously downloaded",
                    message: "No new file was created. This link appears in Track Downloader's download history; check your local collection.",
                    technicalDetails: nil
                )
            )
        case "generic-failure":
            state = .failed(
                DownloadFailurePresentation(
                    kind: .extractor,
                    title: "Source could not be downloaded",
                    message: "The service did not provide an available audio stream for this link.",
                    technicalDetails: "ERROR: Requested format is not available. Try a different authorized source."
                )
            )
        default:
            return nil
        }

        let store = DownloadStore(fixtureState: state, outputDirectory: outputDirectory)
        if case .invalidInput = state {
            store.link = "https://example.com/not-supported"
        }
        if normalizedName == "typed"
            || normalizedName == "preflight-ready"
            || normalizedName == "preflight-unavailable" {
            store.link = "https://music.example/track/example"
        } else if normalizedName == "downloading"
            || normalizedName == "downloading-zero"
            || normalizedName == "downloading-complete" {
            store.link = "https://soundcloud.com/example/night-drive"
        }
        return store
    }

    static func downloadedTracksStore(outputDirectory: URL) -> DownloadedTrackStore? {
        guard let name = fixtureName()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !name.isEmpty else {
            return nil
        }
        return downloadedTracksStore(named: name, outputDirectory: outputDirectory)
    }

    static func downloadedTracksStore(named name: String, outputDirectory: URL) -> DownloadedTrackStore? {
        let result: DownloadedTrackScanResult
        switch name.lowercased() {
        case "collection-empty":
            result = DownloadedTrackScanResult(tracks: [], isOutputDirectoryAvailable: true)
        case "collection-unavailable":
            result = DownloadedTrackScanResult(tracks: [], isOutputDirectoryAvailable: false)
        case "collection-malformed":
            result = DownloadedTrackScanResult(
                tracks: [fixtureTrack(filename: "Recorder Trim.aiff", metadata: nil, savedAt: 1_721_000_000)],
                isOutputDirectoryAvailable: true
            )
        case "collection-long":
            result = DownloadedTrackScanResult(
                tracks: [
                    fixtureTrack(
                        filename: "Long Title.flac",
                        metadata: TrackMetadata(
                            title: "A Genuinely Long Saved Track Title That Exercises Two Lines Without Clipping",
                            artist: "Example Artist"
                        ),
                        savedAt: 1_722_000_000
                    )
                ],
                isOutputDirectoryAvailable: true
            )
        case "collection-multiple":
            let now = Date(timeIntervalSince1970: 1_723_000_000).timeIntervalSince1970
            result = DownloadedTrackScanResult(
                tracks: [
                    fixtureTrack(
                        filename: "Aerial Pattern.m4a",
                        metadata: TrackMetadata(
                            title: "Aerial Pattern",
                            artist: "Example Artist",
                            album: "Soft Focus",
                            genre: "Electronic"
                        ),
                        savedAt: now - 86_400,
                        fileSizeBytes: 14_800_000,
                        relativeDirectory: "SoundCloud / Example Artist"
                    ),
                    fixtureTrack(
                        filename: "Night Drive.opus",
                        metadata: TrackMetadata(title: "Night Drive", artist: "DJ Example"),
                        savedAt: now - (5 * 86_400),
                        fileSizeBytes: 11_200_000,
                        relativeDirectory: "YouTube / DJ Example"
                    ),
                    fixtureTrack(
                        filename: "Recorder Trim.wav",
                        metadata: nil,
                        savedAt: now - (45 * 86_400),
                        fileSizeBytes: 38_600_000,
                        relativeDirectory: "Field Recordings"
                    )
                ],
                isOutputDirectoryAvailable: true
            )
        case "downloading", "downloading-zero", "downloading-complete":
            result = DownloadedTrackScanResult(
                tracks: [
                    fixtureTrack(
                        filename: "Night Drive.opus",
                        metadata: TrackMetadata(
                            title: "Night Drive",
                            artist: "Example Artist",
                            genre: "Electronic"
                        ),
                        savedAt: 1_723_000_000,
                        fileSizeBytes: 11_200_000,
                        relativeDirectory: "SoundCloud / Example Artist"
                    )
                ],
                isOutputDirectoryAvailable: true
            )
        default:
            return nil
        }

        let organization: LibraryOrganization
        if name.lowercased() == "collection-multiple" {
            let trackIDs = result.tracks.map(\.libraryID)
            organization = LibraryOrganization(
                favorites: Set(trackIDs.prefix(1)),
                crates: [
                    TrackCrate(name: "Opening Set", trackIDs: Set(trackIDs.prefix(2)))
                ]
            )
        } else {
            organization = LibraryOrganization()
        }

        return DownloadedTrackStore(
            outputDirectory: outputDirectory,
            scanner: FixtureDownloadedTrackScanner(result: result),
            persistence: MemoryLibraryOrganizationPersistence(organization: organization)
        )
    }

    /// Visual-only launch configuration, intentionally unavailable in release builds.
    static var appearanceConfiguration: AppearanceConfiguration {
        AppearanceConfiguration(
            colorScheme: appearanceValue("TrackDownloaderAppearance").flatMap { ColorScheme(argumentValue: $0) },
            dynamicTypeSize: appearanceValue("TrackDownloaderTextSize").flatMap { DynamicTypeSize(argumentValue: $0) },
            reduceMotion: appearanceBool("TrackDownloaderReduceMotion")
        )
    }

    static var expandFailureDetails: Bool {
        appearanceBool("TrackDownloaderExpandFailureDetails")
    }

    static var startsFocused: Bool {
        fixtureName()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "focused"
    }

    static var isActive: Bool {
        guard let name = fixtureName()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !name.isEmpty
    }

    static var showsSettingsAbout: Bool {
        let name = fixtureName()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name == "settings-about" || name?.hasPrefix("settings-update-") == true
    }

    static var updateStatus: UpdateStatus? {
        switch fixtureName()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "update-available", "settings-update-available":
            return .available(fixtureUpdateRelease)
        case "settings-update-checking":
            return .checking
        case "settings-update-up-to-date":
            return .upToDate
        case "settings-update-failure":
            return .manualFailure("Couldn't check for updates. Check your connection and try again.")
        default:
            return nil
        }
    }

    private static var fixtureUpdateRelease: UpdateRelease {
        UpdateRelease(
            version: StableVersion(releaseTag: "v1.1.0")!,
            notes: "Safer downloads and clearer errors.",
            pageURL: URL(string: "https://github.com/jackirvinee/track-downloader/releases/tag/v1.1.0")!
        )
    }

    private static func fixtureName() -> String? {
        if let environmentName = ProcessInfo.processInfo.environment["TRACK_DOWNLOADER_FIXTURE"] {
            return environmentName
        }
        if let argumentDomainName = UserDefaults.standard.string(forKey: "TrackDownloaderFixture") {
            return argumentDomainName
        }

        let arguments = ProcessInfo.processInfo.arguments
        if let inline = arguments.first(where: { $0.hasPrefix("--fixture=") }) {
            return String(inline.dropFirst("--fixture=".count))
        }
        if let flagIndex = arguments.firstIndex(of: "--fixture"),
           arguments.indices.contains(flagIndex + 1) {
            return arguments[flagIndex + 1]
        }
        return nil
    }

    private static func fixtureTrack(
        filename: String,
        metadata: TrackMetadata?,
        savedAt: TimeInterval,
        fileSizeBytes: Int64? = nil,
        relativeDirectory: String? = nil
    ) -> DownloadedTrack {
        DownloadedTrack(
            fileURL: URL(fileURLWithPath: "/tmp/track-downloader-fixture-output/\(filename)"),
            metadata: metadata,
            savedAt: Date(timeIntervalSince1970: savedAt),
            fileSizeBytes: fileSizeBytes,
            relativeDirectory: relativeDirectory
        )
    }

    private static func appearanceValue(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    private static func appearanceBool(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key).flatMap { value in
            switch value {
            case let bool as Bool:
                return bool
            case let string as String:
                return ["yes", "true", "1"].contains(string.lowercased())
            default:
                return nil
            }
        } ?? false
    }

    private static func result(
        kbps: Int?,
        codec: String,
        sampleRate: Int?,
        verdict: QualityVerdict,
        metadata: TrackMetadata = TrackMetadata(
            title: "Evening Set",
            artist: "Example Artist",
            album: "Track Downloader Fixture"
        )
    ) -> DownloadResult {
        let fileURL = URL(fileURLWithPath: "/tmp/track-downloader-fixture-output/Example Artist - Evening Set.opus")
        return DownloadResult(
            fileURL: fileURL,
            metadata: metadata,
            quality: AudioQuality(
                fileURL: fileURL,
                codec: codec,
                kbps: kbps,
                sampleRateHz: sampleRate,
                verdict: verdict
            )
        )
    }
}

private struct FixtureDownloadedTrackScanner: DownloadedTrackScanning {
    let result: DownloadedTrackScanResult

    func scan(in outputDirectory: URL) -> DownloadedTrackScanResult {
        result
    }
}

struct AppearanceConfiguration {
    let colorScheme: ColorScheme?
    let dynamicTypeSize: DynamicTypeSize?
    let reduceMotion: Bool
}

private extension ColorScheme {
    init?(argumentValue: String) {
        switch argumentValue.lowercased() {
        case "light": self = .light
        case "dark": self = .dark
        default: return nil
        }
    }
}

private extension DynamicTypeSize {
    init?(argumentValue: String) {
        switch argumentValue.lowercased() {
        case "xsmall": self = .xSmall
        case "small": self = .small
        case "medium": self = .medium
        case "large": self = .large
        case "xlarge": self = .xLarge
        case "xxlarge": self = .xxLarge
        case "xxxlarge": self = .xxxLarge
        case "accessibility1": self = .accessibility1
        case "accessibility2": self = .accessibility2
        case "accessibility3": self = .accessibility3
        case "accessibility4": self = .accessibility4
        case "accessibility5": self = .accessibility5
        default: return nil
        }
    }
}

private struct FixtureReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var trackDownloaderFixtureReduceMotion: Bool {
        get { self[FixtureReduceMotionKey.self] }
        set { self[FixtureReduceMotionKey.self] = newValue }
    }
}

struct FixtureDownloadService: DownloadServicing {
    let outputDirectory: URL

    func download(
        sourceURL: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        throw DownloadFailurePresentation(
            kind: .unexpected,
            title: "Fixture mode",
            message: "Fixture mode never starts a downloader process.",
            technicalDetails: nil
        )
    }

    func cancel() {}
}
#endif
