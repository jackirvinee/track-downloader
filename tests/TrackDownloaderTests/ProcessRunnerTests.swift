import Foundation
import XCTest
@testable import TrackDownloader

final class ProcessRunnerTests: XCTestCase {
    func testStreamsLinesInOrderAndPreservesCompleteOutputAndExitStatus() async throws {
        let recorder = LineRecorder()
        let runner = ProcessRunner()

        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'first\\n'; printf 'second\\n' >&2; printf 'final'; exit 7"],
            onLine: { recorder.record($0) }
        )

        XCTAssertEqual(recorder.lines, ["first", "second", "final"])
        XCTAssertEqual(result.output, "first\nsecond\nfinal")
        XCTAssertEqual(result.exitCode, 7)
    }

    func testCancelTerminatesOnlyTheRunnerChild() async throws {
        let runner = ProcessRunner()
        let unrelatedProcess = Process()
        unrelatedProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        unrelatedProcess.arguments = ["-c", "exec sleep 10"]
        try unrelatedProcess.run()
        defer {
            if unrelatedProcess.isRunning {
                unrelatedProcess.terminate()
                unrelatedProcess.waitUntilExit()
            }
        }

        let recorder = LineRecorder()
        let startedAt = Date()
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'ready\\n'; exec sleep 10"],
                onLine: { recorder.record($0) }
            )
        }

        XCTAssertEqual(recorder.waitForLine(timeout: 1), .success)
        runner.cancel()

        let result = try await task.value
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(unrelatedProcess.isRunning)
    }

    func testRepeatedCancellationWithBufferedOutputDoesNotAccessAClosedDescriptor() async throws {
        for _ in 0..<100 {
            let runner = ProcessRunner()
            let recorder = LineRecorder()
            let task = Task {
                try await runner.run(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "printf 'ready\\n'; i=0; while [ \"$i\" -lt 256 ]; do printf 'chunk-%04d\\n' \"$i\"; i=$((i + 1)); done; exec sleep 10"
                    ],
                    onLine: { recorder.record($0) }
                )
            }

            XCTAssertEqual(recorder.waitForLine(timeout: 1), .success)
            runner.cancel()

            let result = try await task.value
            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertTrue(result.output.contains("ready\n"))
        }
    }

    func testCancellationBeforeLaunchNeverStartsTheChild() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("started")
        let runner = ProcessRunner()

        let task = Task {
            // Cancel this task deterministically before the runner launches.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [marker.path],
                onLine: { _ in }
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected a cancelled run to throw before launching.")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testTaskCancellationStopsTheRunningChild() async throws {
        let runner = ProcessRunner()
        let recorder = LineRecorder()
        let startedAt = Date()
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'ready\\n'; exec sleep 10"],
                onLine: { recorder.record($0) }
            )
        }

        XCTAssertEqual(recorder.waitForLine(timeout: 1), .success)
        task.cancel()

        let result = try await task.value
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testCancelInterruptsSoTheChildCanStopItsOwnSubprocess() async throws {
        // Like yt-dlp with ffmpeg: the child only stops its subprocess when it is
        // interrupted. A plain terminate would leave the `sleep` running.
        let script = #"trap 'kill "$child"; wait "$child"; exit 130' INT; "#
            + #"sleep 30 >/dev/null 2>&1 & child=$!; printf "ready %s\n" "$child"; wait "$child""#
        let runner = ProcessRunner()
        let recorder = LineRecorder()
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                onLine: { recorder.record($0) }
            )
        }

        XCTAssertEqual(recorder.waitForLine(timeout: 1), .success)
        let grandchild = try XCTUnwrap(
            recorder.lines.first.flatMap { Int32($0.split(separator: " ").last ?? "") }
        )
        defer { _ = kill(grandchild, SIGKILL) }
        runner.cancel()

        let result = try await task.value
        XCTAssertEqual(result.exitCode, 130)
        XCTAssertEqual(kill(grandchild, 0), -1, "The child's own subprocess should have been stopped.")
    }

    func testPassesProvidedFileHandleToChildStandardInput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaURL = directory.appendingPathComponent("media-input")
        try Data("pinned-media-bytes".utf8).write(to: mediaURL)
        let input = try FileHandle(forReadingFrom: mediaURL)
        defer { try? input.close() }

        let result = try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cat"],
            standardInput: input,
            onLine: { _ in }
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "pinned-media-bytes")
    }
}

private final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let lineReceived = DispatchSemaphore(value: 0)
    private var recordedLines: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedLines
    }

    func record(_ line: String) {
        lock.lock()
        recordedLines.append(line)
        lock.unlock()
        lineReceived.signal()
    }

    func waitForLine(timeout: TimeInterval) -> DispatchTimeoutResult {
        lineReceived.wait(timeout: .now() + timeout)
    }
}
