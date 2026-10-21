import Foundation
import XCTest
@testable import TrackDownloader
@testable import TrackDownloaderCore

final class SourcePreflightServiceTests: XCTestCase {
    func testInspectsSourceWithResolvedYTDLPAndNoMediaCommand() async throws {
        let runner = RecordingPreflightProcessRunner(
            result: .init(exitCode: 0, output: validSourceJSON)
        )
        let resolver = ToolResolutionRecorder()
        let service = SourcePreflightService(
            processRunner: runner,
            toolResolver: { try resolver.resolve($0) }
        )
        let sourceURL = URL(string: "https://soundcloud.com/artist/night-drive")!

        let result = try await service.inspect(sourceURL: sourceURL)

        XCTAssertEqual(resolver.resolvedTools, ["yt-dlp", "deno"])
        XCTAssertEqual(runner.invocation?.executable.path, "/opt/homebrew/bin/yt-dlp")
        XCTAssertEqual(
            runner.invocation?.arguments,
            SourcePreflightCommandBuilder.arguments(
                sourceURL: sourceURL,
                denoPath: "/opt/homebrew/bin/deno"
            )
        )
        XCTAssertEqual(
            value(after: "--js-runtimes", in: try XCTUnwrap(runner.invocation?.arguments)),
            "deno:/opt/homebrew/bin/deno"
        )
        XCTAssertEqual(result.title, "Night Drive")
    }

    func testServiceBoundaryNeverPassesMediaOrPersistenceArguments() async throws {
        let runner = RecordingPreflightProcessRunner(
            result: .init(exitCode: 0, output: validSourceJSON)
        )
        let service = SourcePreflightService(
            processRunner: runner,
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        _ = try await service.inspect(sourceURL: URL(string: "https://youtu.be/example")!)

        let forbidden = [
            "--paths", "--output", "--download-archive", "--extract-audio",
            "--audio-format", "--embed-metadata", "--embed-thumbnail",
            "--convert-thumbnails", "--write-info-json", "--cookies-from-browser",
            "--print", "--progress", "--postprocessor-args"
        ]
        let arguments = try XCTUnwrap(runner.invocation?.arguments)
        forbidden.forEach { XCTAssertFalse(arguments.contains($0), "Unexpected \($0)") }
    }

    func testMissingToolMapsToSanitizedDependencyError() async {
        let service = SourcePreflightService(
            processRunner: RecordingPreflightProcessRunner(result: .init(exitCode: 0, output: validSourceJSON)),
            toolResolver: { name in throw ToolResolutionError.missingTool(name) }
        )

        await assertServiceError(
            from: service,
            expected: .missingDependency(name: "yt-dlp")
        )
    }

    func testClassifiesPrivateUnavailableAndTransientFailuresWithoutLeakingOutput() async {
        let source = "https://soundcloud.com/private/secret?token=Cookie-Authorization"
        let cases: [(String, SourcePreflightServiceError)] = [
            ("ERROR: Sign in to confirm you are not a bot", .privateSource),
            ("ERROR: Video unavailable. This video has been removed", .unavailable),
            ("ERROR: HTTP Error 429: Too Many Requests", .transient),
            ("ERROR: arbitrary extractor failure for \(source)", .transient)
        ]

        for (output, expected) in cases {
            let service = SourcePreflightService(
                processRunner: RecordingPreflightProcessRunner(
                    result: .init(exitCode: 1, output: output)
                ),
                toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
            )

            await assertServiceError(from: service, expected: expected)
            let message = expected.message
            XCTAssertFalse(message.localizedCaseInsensitiveContains("soundcloud.com"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("cookie"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("authorization"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("arbitrary extractor"))
        }
    }

    func testMalformedSuccessfulJSONMapsToInvalidResponse() async {
        let service = SourcePreflightService(
            processRunner: RecordingPreflightProcessRunner(
                result: .init(exitCode: 0, output: "{not json}")
            ),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        await assertServiceError(from: service, expected: .invalidResponse)
    }

    func testOversizedSuccessfulOutputMapsToOversizedResponse() async {
        let service = SourcePreflightService(
            processRunner: RecordingPreflightProcessRunner(
                result: .init(
                    exitCode: 0,
                    output: String(repeating: " ", count: SourcePreflightParser.maximumJSONBytes + 1)
                )
            ),
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        await assertServiceError(from: service, expected: .oversizedResponse)
    }

    func testCancelOnlyCancelsTheDedicatedProcessRunner() {
        let runner = RecordingPreflightProcessRunner(result: .init(exitCode: 0, output: validSourceJSON))
        let service = SourcePreflightService(
            processRunner: runner,
            toolResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        service.cancel()

        XCTAssertEqual(runner.cancelCount, 1)
    }

    private func assertServiceError(
        from service: SourcePreflightService,
        expected: SourcePreflightServiceError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await service.inspect(sourceURL: URL(string: "https://youtu.be/example")!)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as SourcePreflightServiceError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private final class RecordingPreflightProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private let result: CommandResult
    private(set) var invocation: Invocation?
    private(set) var cancelCount = 0

    init(result: CommandResult) {
        self.result = result
    }

    func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        invocation = Invocation(executable: executable, arguments: arguments)
        return result
    }

    func run(
        executable: URL,
        arguments: [String],
        standardInput: FileHandle?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        try await run(executable: executable, arguments: arguments, onLine: onLine)
    }

    func cancel() {
        cancelCount += 1
    }
}

private final class ToolResolutionRecorder: @unchecked Sendable {
    private(set) var resolvedTools: [String] = []

    func resolve(_ name: String) throws -> URL {
        resolvedTools.append(name)
        return URL(fileURLWithPath: "/opt/homebrew/bin/\(name)")
    }
}

private let validSourceJSON = """
{
  "title": "Night Drive",
  "requested_downloads": [{"acodec": "opus", "abr": 192, "asr": 48000}]
}
"""
