import Foundation
import XCTest
@testable import TrackDownloader

final class EngineHealthServiceTests: XCTestCase {
    func testReportsRecognizedVersionsUsingOnlyPerToolLocalVersionCommands() async {
        let runner = RecordingProcessRunner(responses: [
            "yt-dlp": .init(exitCode: 0, output: "2026.08.14\n"),
            "ffmpeg": .init(exitCode: 0, output: "ffmpeg version 8.0 Copyright (c) the FFmpeg developers\n"),
            "ffprobe": .init(exitCode: 0, output: "ffprobe version 8.0 Copyright (c) the FFmpeg developers\n"),
            "deno": .init(exitCode: 0, output: "deno 2.4.3 (stable, release, aarch64-apple-darwin)\n")
        ])
        let service = EngineHealthService(
            processRunner: runner,
            toolResolver: { URL(fileURLWithPath: "/local/\($0)") }
        )

        let snapshot = await service.check()

        XCTAssertEqual(snapshot.tools, [
            EngineToolHealth(id: .ytDLP, status: .available(version: "2026.08.14"), recoveryCommand: nil),
            EngineToolHealth(id: .ffmpeg, status: .available(version: "8.0"), recoveryCommand: nil),
            EngineToolHealth(id: .ffprobe, status: .available(version: "8.0"), recoveryCommand: nil),
            EngineToolHealth(id: .deno, status: .available(version: "2.4.3"), recoveryCommand: nil)
        ])
        XCTAssertTrue(snapshot.ejsEnabled)
        XCTAssertEqual(runner.invocations, [
            .init(executable: URL(fileURLWithPath: "/local/yt-dlp"), arguments: ["--version"]),
            .init(executable: URL(fileURLWithPath: "/local/ffmpeg"), arguments: ["-version"]),
            .init(executable: URL(fileURLWithPath: "/local/ffprobe"), arguments: ["-version"]),
            .init(executable: URL(fileURLWithPath: "/local/deno"), arguments: ["--version"])
        ])
    }

    func testRejectsVersionOutputLargerThanBoundBeforeParsing() async {
        let runner = RecordingProcessRunner(responses: [
            "yt-dlp": .init(exitCode: 0, output: String(repeating: "x", count: 16_385)),
            "ffmpeg": .init(exitCode: 0, output: String(repeating: "x", count: 16_385)),
            "ffprobe": .init(exitCode: 0, output: String(repeating: "x", count: 16_385)),
            "deno": .init(exitCode: 0, output: String(repeating: "x", count: 16_385))
        ])
        let service = EngineHealthService(
            processRunner: runner,
            toolResolver: { URL(fileURLWithPath: "/local/\($0)") }
        )

        let snapshot = await service.check()

        XCTAssertEqual(snapshot.tools, [
            EngineToolHealth(id: .ytDLP, status: .versionUnrecognized, recoveryCommand: "brew upgrade yt-dlp"),
            EngineToolHealth(id: .ffmpeg, status: .versionUnrecognized, recoveryCommand: "brew upgrade ffmpeg"),
            EngineToolHealth(id: .ffprobe, status: .versionUnrecognized, recoveryCommand: "brew upgrade ffmpeg"),
            EngineToolHealth(id: .deno, status: .versionUnrecognized, recoveryCommand: "brew upgrade deno")
        ])
    }

    func testMissingAndMalformedToolsHaveInertRecoveryStringsWithoutAdditionalProcesses() async {
        let runner = RecordingProcessRunner(responses: [
            "ffmpeg": .init(exitCode: 0, output: "ffmpeg version 8.0\n"),
            "deno": .init(exitCode: 0, output: "not a Deno version\n")
        ])
        let service = EngineHealthService(
            processRunner: runner,
            toolResolver: { name in
                if name == "yt-dlp" || name == "ffprobe" {
                    throw ToolResolutionError.missingTool(name)
                }
                return URL(fileURLWithPath: "/local/\(name)")
            }
        )

        let snapshot = await service.check()

        XCTAssertEqual(snapshot.tools, [
            EngineToolHealth(id: .ytDLP, status: .unavailable, recoveryCommand: "brew install yt-dlp"),
            EngineToolHealth(id: .ffmpeg, status: .available(version: "8.0"), recoveryCommand: nil),
            EngineToolHealth(id: .ffprobe, status: .unavailable, recoveryCommand: "brew install ffmpeg"),
            EngineToolHealth(id: .deno, status: .versionUnrecognized, recoveryCommand: "brew upgrade deno")
        ])
        XCTAssertEqual(runner.invocations.map(\.executable.lastPathComponent), ["ffmpeg", "deno"])

        let invocationCount = runner.invocations.count
        XCTAssertEqual(snapshot.tools.compactMap(\.recoveryCommand), [
            "brew install yt-dlp",
            "brew install ffmpeg",
            "brew upgrade deno"
        ])
        XCTAssertEqual(runner.invocations.count, invocationCount)
    }
}

private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private let lock = NSLock()
    private let responses: [String: CommandResult]
    private var recordedInvocations: [Invocation] = []

    init(responses: [String: CommandResult]) {
        self.responses = responses
    }

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations
    }

    func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        record(Invocation(executable: executable, arguments: arguments))
        return responses[executable.lastPathComponent] ?? CommandResult(exitCode: 1, output: "")
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

    private func record(_ invocation: Invocation) {
        lock.lock()
        recordedInvocations.append(invocation)
        lock.unlock()
    }
}
