import TrackDownloaderCore
import Foundation
import XCTest
@testable import TrackDownloader

final class DownloaderServiceTests: XCTestCase {
    func testDefaultOutputDirectoryIsTrackDownloaderInDownloads() {
        let expected = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Track Downloader", isDirectory: true)

        XCTAssertEqual(DownloaderService.defaultOutputDirectory, expected)
        XCTAssertEqual(DownloaderService().outputDirectory, expected)
    }

    func testPassesResolvedDenoAndFFmpegPathsToYTDLP() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = StubProcessRunner(responses: [
            .init(lines: [], result: .init(exitCode: 1, output: "ERROR: expected test failure"))
        ])
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: runner,
            toolResolver: { name in
                URL(fileURLWithPath: "/opt/homebrew/bin/\(name)")
            }
        )

        _ = try await downloadFailure(from: service)

        let arguments = try XCTUnwrap(runner.invocations.first?.arguments)
        XCTAssertEqual(value(after: "--js-runtimes", in: arguments), "deno:/opt/homebrew/bin/deno")
        XCTAssertEqual(value(after: "--ffmpeg-location", in: arguments), "/opt/homebrew/bin/ffmpeg")
    }

    func testReportsStructuredStagesAndReturnsSidecarMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Primary Artist - Night Drive.opus")
        try Data().write(to: fileURL)
        try Data("""
        {
          "title": "Night Drive",
          "artist": "Primary Artist",
          "album": "After Hours",
          "genre": "Electronic"
        }
        """.utf8).write(to: directory.appendingPathComponent("Primary Artist - Night Drive.info.json"))

        let runner = StubProcessRunner(responses: [
            .init(
                lines: [
                    "track-downloader:progress:42.5|3.2MiB/s|00:12",
                    "track-downloader:postprocess:EmbedThumbnail",
                    "track-downloader:filepath:\(fileURL.path)"
                ],
                result: .init(exitCode: 0, output: "track-downloader:filepath:\(fileURL.path)\n")
            ),
            .init(
                lines: [],
                result: .init(
                    exitCode: 0,
                    output: """
                    {"streams":[{"codec_type":"audio","codec_name":"opus","bit_rate":"192000","sample_rate":"48000"}],"format":{"bit_rate":"192000"}}
                    """
                )
            )
        ])
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: runner,
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )
        let progress = ProgressRecorder()

        let result = try await service.download(sourceURL: URL(string: "https://soundcloud.com/artist/night-drive")!) {
            progress.record($0)
        }

        XCTAssertEqual(result.fileURL, fileURL)
        XCTAssertEqual(result.metadata.title, "Night Drive")
        XCTAssertEqual(result.metadata.artist, "Primary Artist")
        XCTAssertEqual(result.metadata.album, "After Hours")
        XCTAssertEqual(result.metadata.genre, "Electronic")
        XCTAssertEqual(result.quality.codec, "opus")
        XCTAssertEqual(progress.values.map(\.stage), [.resolving, .downloading, .processing, .measuringQuality])
        XCTAssertEqual(progress.values[1].fractionCompleted, 0.425)
        XCTAssertEqual(progress.values[1].detail, "3.2MiB/s · 00:12")
    }

    func testPassesSoundCloudSignInOnlyForSoundCloudLinks() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = StubProcessRunner(responses: [
            .init(lines: [], result: .init(exitCode: 1, output: "ERROR: expected test failure")),
            .init(lines: [], result: .init(exitCode: 1, output: "ERROR: expected test failure"))
        ])
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: runner,
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") },
            signIn: { SoundCloudSignIn(browser: .chrome, profile: "Profile 9") }
        )

        _ = try await downloadFailure(from: service)
        _ = try? await service.download(sourceURL: URL(string: "https://youtu.be/example")!) { _ in }

        let soundCloud = try XCTUnwrap(runner.invocations.first?.arguments)
        XCTAssertEqual(value(after: "--cookies-from-browser", in: soundCloud), "chrome:Profile 9")
        let youTube = try XCTUnwrap(runner.invocations.last?.arguments)
        XCTAssertFalse(youTube.contains("--cookies-from-browser"))
    }

    func testScrubsCookiesFromSidecarsEvenWhenDownloadFails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecar = directory.appendingPathComponent("Soundcloud/Artist - Track [1].info.json")
        let untouched = directory.appendingPathComponent("Old.info.json")
        let runner = StubProcessRunner(responses: [
            .init(lines: [], result: .init(exitCode: 1, output: "ERROR: expected test failure"))
        ])
        runner.beforeFirstRun = {
            try? FileManager.default.createDirectory(
                at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? Data(#"{"title":"Track","formats":[{"cookies":"oauth_token=SECRET"}]}"#.utf8).write(to: sidecar)
        }
        try Data(#"{"title":"Old","cookies":"left alone"}"#.utf8).write(to: untouched)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: untouched.path
        )
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: runner,
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") },
            signIn: { SoundCloudSignIn(browser: .chrome, profile: "") }
        )

        _ = try await downloadFailure(from: service)

        let cleaned = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertFalse(cleaned.contains("SECRET"))
        XCTAssertTrue(cleaned.contains("Track"))
        XCTAssertTrue(try String(contentsOf: untouched, encoding: .utf8).contains("left alone"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sidecar.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, [sidecar.lastPathComponent])
    }

    func testKeepsDownloadedTrackWhenItsInfoSidecarIsMalformed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Unknown Artist - Track.opus")
        try Data().write(to: fileURL)
        try Data("{not valid json}".utf8).write(to: directory.appendingPathComponent("Unknown Artist - Track.info.json"))

        let runner = StubProcessRunner(responses: [
            .init(
                lines: ["track-downloader:filepath:\(fileURL.path)"],
                result: .init(exitCode: 0, output: "track-downloader:filepath:\(fileURL.path)\n")
            ),
            .init(
                lines: [],
                result: .init(exitCode: 0, output: "{\"streams\":[]}"))
        ])
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: runner,
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let result = try await service.download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.fileURL, fileURL)
        XCTAssertEqual(result.metadata.title, "Unknown Artist - Track")
        XCTAssertNil(result.metadata.artist)
        XCTAssertEqual(result.quality.verdict, .unknown)
    }

    func testRejectsSidecarSymlinkThatResolvesOutsideOutputDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        let outsideDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }
        let fileURL = directory.appendingPathComponent("Artist - Track.opus")
        let outsideSidecar = outsideDirectory.appendingPathComponent("outside.info.json")
        let linkedSidecar = fileURL.appendingPathExtension("info.json")
        try Data().write(to: fileURL)
        try Data("{\"title\": \"Outside Metadata\", \"artist\": \"Outside Artist\"}".utf8)
            .write(to: outsideSidecar)
        try FileManager.default.createSymbolicLink(at: linkedSidecar, withDestinationURL: outsideSidecar)

        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(
                    lines: ["track-downloader:filepath:\(fileURL.path)"],
                    result: .init(exitCode: 0, output: "track-downloader:filepath:\(fileURL.path)\n")
                ),
                .init(lines: [], result: .init(exitCode: 0, output: validQualityJSON))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let result = try await service.download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.metadata.title, "Artist - Track")
        XCTAssertNil(result.metadata.artist)
    }

    func testReadsContainedAlternateSidecarMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Artist - Track.opus")
        try Data().write(to: fileURL)
        try Data("{\"title\": \"Contained Metadata\", \"artist\": \"Contained Artist\"}".utf8)
            .write(to: fileURL.appendingPathExtension("info.json"))

        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(
                    lines: ["track-downloader:filepath:\(fileURL.path)"],
                    result: .init(exitCode: 0, output: "track-downloader:filepath:\(fileURL.path)\n")
                ),
                .init(lines: [], result: .init(exitCode: 0, output: validQualityJSON))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let result = try await service.download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.metadata.title, "Contained Metadata")
        XCTAssertEqual(result.metadata.artist, "Contained Artist")
    }

    func testDoesNotFollowContainedSidecarSymlink() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Artist - Track.opus")
        let protectedSidecar = directory.appendingPathComponent("protected.info.json")
        let linkedSidecar = fileURL.appendingPathExtension("info.json")
        try Data().write(to: fileURL)
        try Data("{\"title\": \"Protected Metadata\", \"artist\": \"Protected Artist\"}".utf8)
            .write(to: protectedSidecar)
        try FileManager.default.createSymbolicLink(at: linkedSidecar, withDestinationURL: protectedSidecar)

        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(
                    lines: ["track-downloader:filepath:\(fileURL.path)"],
                    result: .init(exitCode: 0, output: "track-downloader:filepath:\(fileURL.path)\n")
                ),
                .init(lines: [], result: .init(exitCode: 0, output: validQualityJSON))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let result = try await service.download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.metadata.title, "Artist - Track")
        XCTAssertNil(result.metadata.artist)
    }

    func testRejectsLastDownloadLogSymlinkThatResolvesOutsideOutputDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        let outsideDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }
        let fileURL = directory.appendingPathComponent("Artist - Track.opus")
        let outsideLog = outsideDirectory.appendingPathComponent("protected.log")
        let linkedLog = directory.appendingPathComponent("track-downloader-last-download.log")
        try Data().write(to: fileURL)
        try Data("must remain unchanged\n".utf8).write(to: outsideLog)
        try FileManager.default.createSymbolicLink(at: linkedLog, withDestinationURL: outsideLog)

        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(
                    lines: ["track-downloader:filepath:\(fileURL.path)"],
                    result: .init(exitCode: 0, output: "track-downloader:filepath:\(fileURL.path)\n")
                ),
                .init(lines: [], result: .init(exitCode: 0, output: validQualityJSON))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let didReject = await downloadDidThrow(service)
        XCTAssertTrue(didReject)
        XCTAssertEqual(try String(contentsOf: outsideLog), "must remain unchanged\n")
    }

    func testDoesNotFollowContainedLastDownloadLogSymlink() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Artist - Track.opus")
        let protectedLog = directory.appendingPathComponent("protected.log")
        let linkedLog = directory.appendingPathComponent("track-downloader-last-download.log")
        try Data().write(to: fileURL)
        try Data("must remain unchanged\n".utf8).write(to: protectedLog)
        try FileManager.default.createSymbolicLink(at: linkedLog, withDestinationURL: protectedLog)

        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(
                    lines: ["track-downloader:filepath:\(fileURL.path)"],
                    result: .init(exitCode: 0, output: "track-downloader:filepath:\(fileURL.path)\n")
                ),
                .init(lines: [], result: .init(exitCode: 0, output: validQualityJSON))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let didReject = await downloadDidThrow(service)

        XCTAssertTrue(didReject)
        XCTAssertEqual(try String(contentsOf: protectedLog), "must remain unchanged\n")
    }

    func testRejectsQualityReportSymlinkThatResolvesOutsideOutputDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        let outsideDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }
        let fileURL = directory.appendingPathComponent("Artist - Track.opus")
        let outsideReport = outsideDirectory.appendingPathComponent("protected.txt")
        let linkedReport = directory.appendingPathComponent("track-downloader-quality-report.txt")
        try Data().write(to: fileURL)
        try Data("must remain unchanged\n".utf8).write(to: outsideReport)
        try FileManager.default.createSymbolicLink(at: linkedReport, withDestinationURL: outsideReport)

        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(
                    lines: ["track-downloader:filepath:\(fileURL.path)"],
                    result: .init(exitCode: 0, output: "track-downloader:filepath:\(fileURL.path)\n")
                ),
                .init(lines: [], result: .init(exitCode: 0, output: validQualityJSON))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let didReject = await downloadDidThrow(service)
        XCTAssertTrue(didReject)
        XCTAssertEqual(try String(contentsOf: outsideReport), "must remain unchanged\n")
    }

    func testPersistsRedactedExtractorOutputWhileKeepingBenignDiagnostics() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let extractorOutput = """
        ERROR: Video unavailable
        Request: https://example.invalid/watch?api_token=top-secret-token
        Authorization: Bearer bearer-secret-value
        Cookie: session=private-cookie-value
        api-token: standalone-api-token-secret
        """
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(lines: [], result: .init(exitCode: 1, output: extractorOutput))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let didThrow = await downloadDidThrow(service)
        XCTAssertTrue(didThrow)

        let persistedLog = try String(
            contentsOf: directory.appendingPathComponent("track-downloader-last-download.log")
        )
        XCTAssertTrue(persistedLog.contains("ERROR: Video unavailable"))
        XCTAssertFalse(persistedLog.contains("https://example.invalid"))
        XCTAssertFalse(persistedLog.contains("top-secret-token"))
        XCTAssertFalse(persistedLog.contains("bearer-secret-value"))
        XCTAssertFalse(persistedLog.contains("private-cookie-value"))
        XCTAssertFalse(persistedLog.contains("standalone-api-token-secret"))
    }

    func testSupportsConfiguredOutputRootSymlinkForContainedSidecarLogAndReport() async throws {
        let parentDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentDirectory) }
        let resolvedOutputDirectory = parentDirectory.appendingPathComponent("resolved-output", isDirectory: true)
        let configuredOutputDirectory = parentDirectory.appendingPathComponent("configured-output", isDirectory: true)
        try FileManager.default.createDirectory(at: resolvedOutputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: configuredOutputDirectory,
            withDestinationURL: resolvedOutputDirectory
        )
        let fileURL = resolvedOutputDirectory.appendingPathComponent("Artist - Track.opus")
        try Data().write(to: fileURL)
        try Data("{\"title\": \"Contained Metadata\", \"artist\": \"Contained Artist\"}".utf8)
            .write(to: fileURL.appendingPathExtension("info.json"))

        let service = DownloaderService(
            outputDirectory: configuredOutputDirectory,
            processRunner: StubProcessRunner(responses: [
                .init(
                    lines: ["track-downloader:filepath:\(fileURL.path)"],
                    result: .init(exitCode: 0, output: "track-downloader:filepath:\(fileURL.path)\n")
                ),
                .init(lines: [], result: .init(exitCode: 0, output: validQualityJSON))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let result = try await service.download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.metadata.title, "Contained Metadata")
        XCTAssertEqual(result.metadata.artist, "Contained Artist")
        XCTAssertTrue(
            try String(contentsOf: resolvedOutputDirectory.appendingPathComponent("track-downloader-last-download.log"))
                .contains("track-downloader:filepath:")
        )
        XCTAssertTrue(
            try String(contentsOf: resolvedOutputDirectory.appendingPathComponent("track-downloader-quality-report.txt"))
                .contains("Artist - Track.opus")
        )
    }

    func testSupportsPrivateTempConfiguredRootForExistingSidecarAndNewLogAndReport() async throws {
        let parentDirectory = URL(
            fileURLWithPath: "/private/tmp/DownloaderServiceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parentDirectory) }
        let resolvedOutputDirectory = parentDirectory.appendingPathComponent("resolved-output", isDirectory: true)
        let configuredOutputDirectory = parentDirectory.appendingPathComponent("configured-output", isDirectory: true)
        try FileManager.default.createDirectory(at: resolvedOutputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: configuredOutputDirectory,
            withDestinationURL: resolvedOutputDirectory
        )
        let fileURL = resolvedOutputDirectory.appendingPathComponent("Artist - Track.opus")
        try Data().write(to: fileURL)
        try Data("{\"title\": \"Contained Metadata\", \"artist\": \"Contained Artist\"}".utf8)
            .write(to: fileURL.appendingPathExtension("info.json"))

        let service = DownloaderService(
            outputDirectory: configuredOutputDirectory,
            processRunner: StubProcessRunner(responses: [
                .init(
                    lines: ["track-downloader:filepath:\(fileURL.path)"],
                    result: .init(exitCode: 0, output: "track-downloader:filepath:\(fileURL.path)\n")
                ),
                .init(lines: [], result: .init(exitCode: 0, output: validQualityJSON))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let result = try await service.download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.fileURL, configuredOutputDirectory.appendingPathComponent("Artist - Track.opus"))
        XCTAssertEqual(result.metadata.title, "Contained Metadata")
        XCTAssertEqual(result.metadata.artist, "Contained Artist")
        XCTAssertTrue(
            try String(contentsOf: configuredOutputDirectory.appendingPathComponent("track-downloader-last-download.log"))
                .contains("track-downloader:filepath:")
        )
        XCTAssertTrue(
            try String(contentsOf: configuredOutputDirectory.appendingPathComponent("track-downloader-quality-report.txt"))
                .contains("Artist - Track.opus")
        )
    }

    func testKeepsRootSwappedMediaInspectionBoundToOpenedM4A() async throws {
        let parentDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentDirectory) }
        let originalOutputDirectory = parentDirectory.appendingPathComponent("original-output", isDirectory: true)
        let alternateOutputDirectory = parentDirectory.appendingPathComponent("alternate-output", isDirectory: true)
        let configuredOutputDirectory = parentDirectory.appendingPathComponent("configured-output", isDirectory: true)
        try FileManager.default.createDirectory(at: originalOutputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alternateOutputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: configuredOutputDirectory, withDestinationURL: originalOutputDirectory)

        let filename = "Artist - Track.m4a"
        let originalMediaURL = originalOutputDirectory.appendingPathComponent(filename)
        let alternateMediaURL = alternateOutputDirectory.appendingPathComponent(filename)
        try makeAudioFixture(at: originalMediaURL, codec: "aac")
        try makeAudioFixture(at: alternateMediaURL, codec: "alac")

        let runner = SwappingQualityProbeRunner(
            finalPath: originalMediaURL.path,
            mutateBeforeQualityProbe: {
                try FileManager.default.removeItem(at: configuredOutputDirectory)
                try FileManager.default.createSymbolicLink(
                    at: configuredOutputDirectory,
                    withDestinationURL: alternateOutputDirectory
                )
            }
        )
        let service = DownloaderService(
            outputDirectory: configuredOutputDirectory,
            processRunner: runner,
            toolResolver: { name in
                name == "ffprobe"
                    ? URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
                    : URL(fileURLWithPath: "/usr/bin/true")
            }
        )

        let result = try await service.download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.quality.codec, "aac")
    }

    func testKeepsMediaInspectionBoundToInitialRootAfterFinalPathSwap() async throws {
        let parentDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentDirectory) }
        let originalOutputDirectory = parentDirectory.appendingPathComponent("original-output", isDirectory: true)
        let alternateOutputDirectory = parentDirectory.appendingPathComponent("alternate-output", isDirectory: true)
        let configuredOutputDirectory = parentDirectory.appendingPathComponent("configured-output", isDirectory: true)
        try FileManager.default.createDirectory(at: originalOutputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alternateOutputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: configuredOutputDirectory, withDestinationURL: originalOutputDirectory)

        let filename = "Artist - Track.m4a"
        let configuredMediaURL = configuredOutputDirectory.appendingPathComponent(filename)
        try makeAudioFixture(at: originalOutputDirectory.appendingPathComponent(filename), codec: "aac")
        try makeAudioFixture(at: alternateOutputDirectory.appendingPathComponent(filename), codec: "alac")

        let service = DownloaderService(
            outputDirectory: configuredOutputDirectory,
            processRunner: FinalPathSwappingProcessRunner(
                finalPath: configuredMediaURL.path,
                mutateAfterFinalPath: {
                    try FileManager.default.removeItem(at: configuredOutputDirectory)
                    try FileManager.default.createSymbolicLink(
                        at: configuredOutputDirectory,
                        withDestinationURL: alternateOutputDirectory
                    )
                }
            ),
            toolResolver: { name in
                name == "ffprobe"
                    ? URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
                    : URL(fileURLWithPath: "/usr/bin/true")
            }
        )

        let result = try await service.download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.quality.codec, "aac")
    }

    func testKeepsChildSwappedMediaInspectionBoundToOpenedWAV() async throws {
        let outputDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let originalChildDirectory = outputDirectory.appendingPathComponent("album", isDirectory: true)
        let alternateChildDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: alternateChildDirectory) }
        try FileManager.default.createDirectory(at: originalChildDirectory, withIntermediateDirectories: true)

        let filename = "Artist - Track.wav"
        let originalMediaURL = originalChildDirectory.appendingPathComponent(filename)
        let alternateMediaURL = alternateChildDirectory.appendingPathComponent(filename)
        try makeAudioFixture(at: originalMediaURL, codec: "pcm_s16le")
        try makeAudioFixture(at: alternateMediaURL, codec: "pcm_u8")

        let runner = SwappingQualityProbeRunner(
            finalPath: originalMediaURL.path,
            mutateBeforeQualityProbe: {
                try FileManager.default.removeItem(at: originalChildDirectory)
                try FileManager.default.createSymbolicLink(
                    at: originalChildDirectory,
                    withDestinationURL: alternateChildDirectory
                )
            }
        )
        let service = DownloaderService(
            outputDirectory: outputDirectory,
            processRunner: runner,
            toolResolver: { name in
                name == "ffprobe"
                    ? URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
                    : URL(fileURLWithPath: "/usr/bin/true")
            }
        )

        let result = try await service.download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.quality.codec, "pcm_s16le")
    }

    func testMeasuresOrdinaryM4AThroughQualityProbe() async throws {
        let outputDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let mediaURL = outputDirectory.appendingPathComponent("Artist - Track.m4a")
        try makeAudioFixture(at: mediaURL, codec: "aac")

        let service = DownloaderService(
            outputDirectory: outputDirectory,
            processRunner: SwappingQualityProbeRunner(finalPath: mediaURL.path, mutateBeforeQualityProbe: {}),
            toolResolver: { name in
                name == "ffprobe"
                    ? URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
                    : URL(fileURLWithPath: "/usr/bin/true")
            }
        )

        let result = try await service.download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.quality.codec, "aac")
    }

    func testConvertsFLACDownloadToWAVThatKeepsItsSidecar() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let flacURL = directory.appendingPathComponent("Artist - Track [1].flac")
        let wavURL = directory.appendingPathComponent("Artist - Track [1].wav")
        try makeAudioFixture(at: flacURL, codec: "flac")
        try Data("{\"title\": \"Night Drive\"}".utf8)
            .write(to: directory.appendingPathComponent("Artist - Track [1].info.json"))

        let result = try await realToolsService(directory, finalPath: flacURL.path)
            .download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.fileURL, wavURL)
        XCTAssertEqual(result.cdjSafety, .converted(.convertToWAV(bitDepth: 16, sampleRateHz: 48_000, downmixToStereo: false)))
        XCTAssertEqual(result.quality.codec, "flac", "quality describes the source, measured before conversion")
        XCTAssertEqual(result.quality.fileURL, wavURL)
        XCTAssertEqual(result.metadata.title, "Night Drive")
        XCTAssertEqual(try audioCodec(of: wavURL), "pcm_s16le")
        XCTAssertFalse(FileManager.default.fileExists(atPath: flacURL.path))
        XCTAssertEqual(try temporaryConversionFiles(in: directory), [])
        XCTAssertTrue(
            try String(contentsOf: directory.appendingPathComponent("track-downloader-quality-report.txt"))
                .contains("Artist - Track [1].wav | ")
        )
    }

    func testRewritesFloatWAVInPlace() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wavURL = directory.appendingPathComponent("Artist - Track.wav")
        try makeAudioFixture(at: wavURL, codec: "pcm_f32le")

        let result = try await realToolsService(directory, finalPath: wavURL.path)
            .download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.fileURL, wavURL)
        XCTAssertEqual(result.cdjSafety, .converted(.convertToWAV(bitDepth: 24, sampleRateHz: 48_000, downmixToStereo: false)))
        XCTAssertEqual(try audioCodec(of: wavURL), "pcm_s24le")
        XCTAssertEqual(try temporaryConversionFiles(in: directory), [])
    }

    func testRewrapsAACSavedWithAnMP3Extension() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mislabeledURL = directory.appendingPathComponent("Artist - Track.mp3")
        try makeAudioFixture(at: mislabeledURL, codec: "aac", format: "adts", duration: "2")

        let result = try await realToolsService(directory, finalPath: mislabeledURL.path)
            .download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        let m4aURL = directory.appendingPathComponent("Artist - Track.m4a")
        XCTAssertEqual(result.fileURL, m4aURL)
        XCTAssertEqual(result.cdjSafety, .converted(.remux(fileExtension: "m4a")))
        XCTAssertEqual(try audioCodec(of: m4aURL), "aac")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mislabeledURL.path))
    }

    func testLeavesDownloadAloneWhenTheConvertedNameIsTaken() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let flacURL = directory.appendingPathComponent("Artist - Track.flac")
        let existingURL = directory.appendingPathComponent("Artist - Track.wav")
        try makeAudioFixture(at: flacURL, codec: "flac")
        try Data("someone else's file".utf8).write(to: existingURL)

        let result = try await realToolsService(directory, finalPath: flacURL.path)
            .download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.fileURL, flacURL)
        XCTAssertEqual(result.cdjSafety, .leftAsDownloaded(reason: "Artist - Track.wav already exists"))
        XCTAssertEqual(try Data(contentsOf: existingURL), Data("someone else's file".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flacURL.path))
    }

    func testLeavesFilesEveryDeckPlaysUntouched() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let m4aURL = directory.appendingPathComponent("Artist - Track.m4a")
        try makeAudioFixture(at: m4aURL, codec: "aac")
        let before = try Data(contentsOf: m4aURL)

        let result = try await realToolsService(directory, finalPath: m4aURL.path)
            .download(sourceURL: URL(string: "https://soundcloud.com/artist/track")!) { _ in }

        XCTAssertEqual(result.fileURL, m4aURL)
        XCTAssertEqual(result.cdjSafety, .alreadySafe)
        XCTAssertEqual(try Data(contentsOf: m4aURL), before)
    }

    func testReportsMissingYTDLPAsAnInstallableDependency() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: []),
            toolResolver: { _ in throw FixtureError.unavailable }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(
            failure,
            DownloadFailurePresentation(
                kind: .missingDependency(
                    name: "yt-dlp",
                    installCommand: "brew install yt-dlp ffmpeg"
                ),
                title: "Missing yt-dlp",
                message: "Install it with Homebrew, then try again.",
                technicalDetails: "brew install yt-dlp ffmpeg"
            )
        )
    }

    func testReportsMissingFFmpegBeforeStartingMediaRequest() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = InvocationRecordingProcessRunner()
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: runner,
            toolResolver: { name in
                guard name == "yt-dlp" else { throw FixtureError.unavailable }
                return URL(fileURLWithPath: "/usr/bin/true")
            }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(
            failure,
            DownloadFailurePresentation(
                kind: .missingDependency(
                    name: "ffmpeg",
                    installCommand: "brew install yt-dlp ffmpeg"
                ),
                title: "Missing ffmpeg",
                message: "Install it with Homebrew, then try again.",
                technicalDetails: "brew install yt-dlp ffmpeg"
            )
        )
        XCTAssertEqual(runner.invocationCount, 0)
    }

    func testReportsMissingDenoBeforeStartingMediaRequest() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = InvocationRecordingProcessRunner()
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: runner,
            toolResolver: { name in
                guard name != "deno" else { throw FixtureError.unavailable }
                return URL(fileURLWithPath: "/usr/bin/true")
            }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(
            failure,
            DownloadFailurePresentation(
                kind: .missingDependency(name: "deno", installCommand: "brew install deno"),
                title: "Missing deno",
                message: "Install it with Homebrew, then try again.",
                technicalDetails: "brew install deno"
            )
        )
        XCTAssertEqual(runner.invocationCount, 0)
    }

    func testReportsMissingFFprobeAsAnInstallableDependency() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Artist - Track.opus")
        try Data().write(to: fileURL)
        let runner = StubProcessRunner(responses: [
            .init(
                lines: ["track-downloader:filepath:\(fileURL.path)"],
                result: .init(exitCode: 0, output: "track-downloader:filepath:\(fileURL.path)\n")
            )
        ])
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: runner,
            toolResolver: { name in
                guard name != "ffprobe" else { throw FixtureError.unavailable }
                return URL(fileURLWithPath: "/usr/bin/true")
            }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(
            failure.kind,
            .missingDependency(
                name: "ffprobe",
                installCommand: "brew install yt-dlp ffmpeg"
            )
        )
        XCTAssertEqual(failure.title, "Missing ffprobe")
        XCTAssertEqual(failure.technicalDetails, "brew install yt-dlp ffmpeg")
    }

    func testReportsExtractorFailureWithConciseMessageAndTechnicalDetails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let extractorOutput = """
        WARNING: [youtube] Falling back to generic extractor
        ERROR: Video unavailable
        """
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(lines: [], result: .init(exitCode: 1, output: extractorOutput))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(failure.kind, .extractor)
        XCTAssertEqual(failure.title, "Download failed")
        XCTAssertEqual(failure.message, "Video unavailable")
        XCTAssertEqual(failure.technicalDetails, extractorOutput)
    }

    func testReportsMissingFinalPathSeparatelyFromQualityFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(lines: [], result: .init(exitCode: 0, output: "completed\n"))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(failure.kind, .outputFileMissing)
        XCTAssertEqual(failure.title, "No downloaded file found")
    }

    func testRejectsExtractorReportedFinalPathOutsideOutputDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outsideDirectory = URL(fileURLWithPath: "\(directory.path)-outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideFile = outsideDirectory.appendingPathComponent("outside-track.opus")
        try Data().write(to: outsideFile)

        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(
                    lines: ["track-downloader:filepath:\(outsideFile.path)"],
                    result: .init(exitCode: 0, output: "track-downloader:filepath:\(outsideFile.path)\n")
                ),
                .init(lines: [], result: .init(exitCode: 0, output: "not json"))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(failure.kind, .outputFileMissing)
    }

    func testRejectsTranscriptFallbackAudioPathThatEscapesThroughSymlink() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outsideDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let escapedDirectory = directory.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: escapedDirectory,
            withDestinationURL: outsideDirectory
        )
        let outsideFile = outsideDirectory.appendingPathComponent("outside-track.opus")
        try Data().write(to: outsideFile)
        let reportedPath = escapedDirectory.appendingPathComponent("outside-track.opus").path

        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(lines: [], result: .init(exitCode: 0, output: "\(reportedPath)\n")),
                .init(lines: [], result: .init(exitCode: 0, output: "not json"))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(failure.kind, .outputFileMissing)
    }

    func testReportsArchivedTrackWithoutInventingAnOutputFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveTranscript = """
        [youtube] Extracting URL: https://youtu.be/already-saved
        [download] already-saved: Night Drive has already been recorded in the archive
        """
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(lines: [], result: .init(exitCode: 0, output: archiveTranscript))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(failure.kind, .alreadyInCollection)
        XCTAssertEqual(failure.title, "Previously downloaded")
        XCTAssertEqual(
            failure.message,
            "No new file was created. This link appears in Track Downloader's download history; check your local collection."
        )
        XCTAssertNil(failure.technicalDetails)
    }

    func testReportsNoOverwriteSkipWithoutInventingAnOutputFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let noOverwriteTranscript = """
        [youtube] Extracting URL: https://youtu.be/already-saved
        [download] Example Artist - Saved Track [already-saved].opus has already been downloaded
        """
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(lines: [], result: .init(exitCode: 0, output: noOverwriteTranscript))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(failure.kind, .alreadyInCollection)
        XCTAssertEqual(failure.title, "Previously downloaded")
        XCTAssertNil(failure.technicalDetails)
    }

    func testDoesNotTreatFilenameContainingArchivePhraseAsHistoryEvidence() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destinationTranscript = """
        [download] Destination: A track has already been downloaded.webm
        """
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(lines: [], result: .init(exitCode: 0, output: destinationTranscript))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(failure.kind, .outputFileMissing)
        XCTAssertEqual(failure.title, "No downloaded file found")
    }

    func testDoesNotTreatDestinationEndingInArchivePhraseAsHistoryEvidence() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destinationTranscript = """
        [download] Destination: A track has already been recorded in the archive
        """
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(lines: [], result: .init(exitCode: 0, output: destinationTranscript))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(failure.kind, .outputFileMissing)
        XCTAssertEqual(failure.title, "No downloaded file found")
    }

    func testDoesNotTreatDestinationEndingInAlreadyDownloadedPhraseAsHistoryEvidence() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destinationTranscript = """
        [download] Destination: A track has already been downloaded
        """
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(lines: [], result: .init(exitCode: 0, output: destinationTranscript))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(failure.kind, .outputFileMissing)
        XCTAssertEqual(failure.title, "No downloaded file found")
    }

    func testDoesNotTreatOrdinaryMissingOutputAsAnArchiveHit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ordinaryTranscript = "[info] This item has already been downloaded by another application\n"
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(lines: [], result: .init(exitCode: 0, output: ordinaryTranscript))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(failure.kind, .outputFileMissing)
        XCTAssertEqual(failure.title, "No downloaded file found")
    }

    func testPreservesTrackAndReportsQualityUnavailableWhenFFprobeFails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Artist - Track.opus")
        try Data().write(to: fileURL)
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(
                    lines: ["track-downloader:filepath:\(fileURL.path)"],
                    result: .init(exitCode: 0, output: "track-downloader:filepath:\(fileURL.path)\n")
                ),
                .init(lines: [], result: .init(exitCode: 1, output: "invalid media\n"))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(failure.kind, .qualityUnavailable)
        XCTAssertEqual(failure.title, "Quality unavailable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testReportsQualityUnavailableWhenFFprobeOutputIsInvalidJSON() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Artist - Track.opus")
        try Data().write(to: fileURL)
        let service = DownloaderService(
            outputDirectory: directory,
            processRunner: StubProcessRunner(responses: [
                .init(
                    lines: ["track-downloader:filepath:\(fileURL.path)"],
                    result: .init(exitCode: 0, output: "track-downloader:filepath:\(fileURL.path)\n")
                ),
                .init(lines: [], result: .init(exitCode: 0, output: "not json"))
            ]),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        let failure = try await downloadFailure(from: service)

        XCTAssertEqual(failure.kind, .qualityUnavailable)
        XCTAssertEqual(failure.title, "Quality unavailable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func downloadFailure(from service: DownloaderService) async throws -> DownloadFailurePresentation {
        do {
            _ = try await service.download(
                sourceURL: URL(string: "https://soundcloud.com/artist/track")!,
                onProgress: { _ in }
            )
        } catch let failure as DownloadFailurePresentation {
            return failure
        } catch {
            XCTFail("Expected DownloadFailurePresentation, got \(error)")
            throw error
        }

        XCTFail("Expected download to fail")
        throw FixtureError.expectedDownloadFailure
    }

    private func downloadDidThrow(_ service: DownloaderService) async -> Bool {
        do {
            _ = try await service.download(
                sourceURL: URL(string: "https://soundcloud.com/artist/track")!,
                onProgress: { _ in }
            )
            return false
        } catch {
            return true
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloaderServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func realToolsService(_ directory: URL, finalPath: String) -> DownloaderService {
        DownloaderService(
            outputDirectory: directory,
            processRunner: DownloadThenRealToolsRunner(finalPath: finalPath),
            toolResolver: { name in
                ["ffprobe", "ffmpeg"].contains(name)
                    ? URL(fileURLWithPath: "/opt/homebrew/bin/\(name)")
                    : URL(fileURLWithPath: "/usr/bin/true")
            }
        )
    }

    private func audioCodec(of fileURL: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        process.arguments = [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name", "-of", "default=nw=1:nk=1",
            fileURL.path
        ]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func temporaryConversionFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(DownloadedTrackScanner.conversionTemporaryPrefix) }
    }

    private var validQualityJSON: String {
        "{\"streams\":[{\"codec_type\":\"audio\",\"codec_name\":\"opus\",\"bit_rate\":\"192000\",\"sample_rate\":\"48000\"}],\"format\":{\"bit_rate\":\"192000\"}}"
    }

    private func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private enum FixtureError: Error {
    case unavailable
    case expectedDownloadFailure
}

private final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation {
        let executable: URL
        let arguments: [String]
    }

    struct Response {
        let lines: [String]
        let result: CommandResult
    }

    private var responses: [Response]
    private(set) var invocations: [Invocation] = []
    /// Stands in for yt-dlp writing files while it runs.
    var beforeFirstRun: (() -> Void)?

    init(responses: [Response]) {
        self.responses = responses
    }

    func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        if invocations.isEmpty { beforeFirstRun?() }
        invocations.append(.init(executable: executable, arguments: arguments))
        // Calls past the scripted ones (the CDJ-safe conversion of a placeholder file) fail,
        // which leaves the download as it was.
        guard !responses.isEmpty else {
            return CommandResult(exitCode: 1, output: "unscripted invocation")
        }
        let response = responses.removeFirst()
        response.lines.forEach(onLine)
        return response.result
    }

    func run(
        executable: URL,
        arguments: [String],
        standardInput: FileHandle?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        try await run(executable: executable, arguments: arguments, onLine: onLine)
    }

    func cancel() {}
}

private final class InvocationRecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        recordInvocation()
        return CommandResult(exitCode: 1, output: "The process runner should not have been invoked.")
    }

    func run(
        executable: URL,
        arguments: [String],
        standardInput: FileHandle?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        try await run(executable: executable, arguments: arguments, onLine: onLine)
    }

    func cancel() {}

    private func recordInvocation() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class SwappingQualityProbeRunner: ProcessRunning, @unchecked Sendable {
    private let finalPath: String
    private let mutateBeforeQualityProbe: () throws -> Void
    private let processRunner = ProcessRunner()
    private var invocationCount = 0

    init(finalPath: String, mutateBeforeQualityProbe: @escaping () throws -> Void) {
        self.finalPath = finalPath
        self.mutateBeforeQualityProbe = mutateBeforeQualityProbe
    }

    func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        invocationCount += 1
        guard invocationCount == 2 else {
            let output = "track-downloader:filepath:\(finalPath)\n"
            onLine(output.trimmingCharacters(in: .newlines))
            return CommandResult(exitCode: 0, output: output)
        }

        try mutateBeforeQualityProbe()
        return try await processRunner.run(
            executable: executable,
            arguments: arguments,
            onLine: onLine
        )
    }

    func run(
        executable: URL,
        arguments: [String],
        standardInput: FileHandle?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        invocationCount += 1
        guard invocationCount == 2 else {
            let output = "track-downloader:filepath:\(finalPath)\n"
            onLine(output.trimmingCharacters(in: .newlines))
            return CommandResult(exitCode: 0, output: output)
        }

        try mutateBeforeQualityProbe()
        return try await processRunner.run(
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            onLine: onLine
        )
    }

    func cancel() {
        processRunner.cancel()
    }
}

private final class FinalPathSwappingProcessRunner: ProcessRunning, @unchecked Sendable {
    private let finalPath: String
    private let mutateAfterFinalPath: () throws -> Void
    private let processRunner = ProcessRunner()
    private var invocationCount = 0

    init(finalPath: String, mutateAfterFinalPath: @escaping () throws -> Void) {
        self.finalPath = finalPath
        self.mutateAfterFinalPath = mutateAfterFinalPath
    }

    func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        invocationCount += 1
        guard invocationCount == 2 else {
            let output = "track-downloader:filepath:\(finalPath)\n"
            onLine(output.trimmingCharacters(in: .newlines))
            try mutateAfterFinalPath()
            return CommandResult(exitCode: 0, output: output)
        }

        return try await processRunner.run(
            executable: executable,
            arguments: arguments,
            onLine: onLine
        )
    }

    func run(
        executable: URL,
        arguments: [String],
        standardInput: FileHandle?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        invocationCount += 1
        guard invocationCount == 2 else {
            let output = "track-downloader:filepath:\(finalPath)\n"
            onLine(output.trimmingCharacters(in: .newlines))
            try mutateAfterFinalPath()
            return CommandResult(exitCode: 0, output: output)
        }

        return try await processRunner.run(
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            onLine: onLine
        )
    }

    func cancel() {
        processRunner.cancel()
    }
}

/// Stands in for yt-dlp on the first call, then runs the real ffprobe/ffmpeg.
private final class DownloadThenRealToolsRunner: ProcessRunning, @unchecked Sendable {
    private let finalPath: String
    private let processRunner = ProcessRunner()
    private var invocationCount = 0

    init(finalPath: String) {
        self.finalPath = finalPath
    }

    func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        try await run(executable: executable, arguments: arguments, standardInput: nil, onLine: onLine)
    }

    func run(
        executable: URL,
        arguments: [String],
        standardInput: FileHandle?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        invocationCount += 1
        guard invocationCount > 1 else {
            let output = "track-downloader:filepath:\(finalPath)\n"
            onLine(output.trimmingCharacters(in: .newlines))
            return CommandResult(exitCode: 0, output: output)
        }
        return try await processRunner.run(
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            onLine: onLine
        )
    }

    func cancel() {
        processRunner.cancel()
    }
}

private func makeAudioFixture(
    at fileURL: URL,
    codec: String,
    format: String? = nil,
    duration: String = "0.1"
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    process.arguments = [
        "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono",
        "-t", duration, "-map", "0:a", "-c:a", codec
    ]
    + (format.map { ["-f", $0] } ?? [])
    + [fileURL.path]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let output = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw NSError(
            domain: "DownloaderServiceTests",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: output]
        )
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [DownloadProgress] = []

    var values: [DownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func record(_ value: DownloadProgress) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }
}
