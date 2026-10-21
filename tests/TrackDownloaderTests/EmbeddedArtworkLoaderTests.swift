import Foundation
import ImageIO
import XCTest
@testable import TrackDownloader

final class EmbeddedArtworkLoaderTests: XCTestCase {
    func testLoadsReadableArtworkEmbeddedInLocalMediaFile() async throws {
        let fixture = try makeMediaFixture(with: .readableArtwork)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let artwork = await EmbeddedArtworkLoader().loadArtwork(from: fixture.mediaURL)

        let data = try XCTUnwrap(artwork)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil))
    }

    func testReturnsNilWhenLocalMediaHasNoEmbeddedArtwork() async throws {
        let fixture = try makeMediaFixture(with: .noArtwork)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let artwork = await EmbeddedArtworkLoader().loadArtwork(from: fixture.mediaURL)

        XCTAssertNil(artwork)
    }

    func testReturnsNilWhenEmbeddedArtworkDataIsMalformed() async throws {
        let fixture = try makeMediaFixture(with: .malformedArtwork)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let artwork = await EmbeddedArtworkLoader().loadArtwork(from: fixture.mediaURL)

        XCTAssertNil(artwork)
    }

    func testReturnsNilForRemoteURLWithoutFetchingIt() async {
        let artwork = await EmbeddedArtworkLoader().loadArtwork(
            from: URL(string: "https://images.example.com/cover.jpg")!
        )

        XCTAssertNil(artwork)
    }
}

private enum ArtworkFixtureKind {
    case readableArtwork
    case noArtwork
    case malformedArtwork
}

private struct MediaFixture {
    let directory: URL
    let mediaURL: URL
}

private func makeMediaFixture(with kind: ArtworkFixtureKind) throws -> MediaFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("EmbeddedArtworkLoaderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let mediaURL = directory.appendingPathComponent("fixture.mp3")
    let artworkURL = directory.appendingPathComponent("cover.png")

    switch kind {
    case .readableArtwork, .malformedArtwork:
        let artwork = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLSpwAAAABJRU5ErkJggg=="))
        try artwork.write(to: artworkURL)
        try runFFmpeg(arguments: [
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
            "-i", artworkURL.path,
            "-t", "0.1",
            "-map", "0:a", "-map", "1:v",
            "-c:a", "libmp3lame", "-c:v", "copy",
            "-id3v2_version", "3",
            "-disposition:v", "attached_pic",
            mediaURL.path
        ])
        if kind == .malformedArtwork {
            var mediaData = try Data(contentsOf: mediaURL)
            let range = try XCTUnwrap(mediaData.range(of: artwork))
            mediaData[range.lowerBound] = 0
            try mediaData.write(to: mediaURL, options: .atomic)
        }
    case .noArtwork:
        try runFFmpeg(arguments: [
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
            "-t", "0.1",
            "-c:a", "libmp3lame",
            mediaURL.path
        ])
    }

    return MediaFixture(directory: directory, mediaURL: mediaURL)
}

private func runFFmpeg(arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"] + arguments
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let output = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw NSError(domain: "EmbeddedArtworkLoaderTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
    }
}
