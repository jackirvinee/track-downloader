import Foundation
import XCTest
@testable import TrackDownloaderChromeCompanion

final class NativeMessageHostTests: XCTestCase {
    func testChromeHostRespondsBeforeChromeClosesInput() throws {
        let hostURL = Bundle(for: NativeMessageHostTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("TrackDownloaderChromeHost")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: hostURL.path))

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = hostURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        defer {
            input.fileHandleForWriting.closeFile()
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let responseExpectation = expectation(description: "native host response")
        var responseFrame = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let availableData = handle.availableData
            guard !availableData.isEmpty else { return }
            responseFrame.append(availableData)
            guard responseFrame.count >= 4 else { return }

            let bytes = [UInt8](responseFrame.prefix(4))
            let payloadLength = Int(bytes[0])
                | Int(bytes[1]) << 8
                | Int(bytes[2]) << 16
                | Int(bytes[3]) << 24
            if responseFrame.count >= payloadLength + 4 {
                handle.readabilityHandler = nil
                responseExpectation.fulfill()
            }
        }

        input.fileHandleForWriting.write(try NativeMessageFrame.encode(Data("not-json".utf8)))
        let waitResult = XCTWaiter.wait(for: [responseExpectation], timeout: 1)
        XCTAssertEqual(waitResult, .completed, "native host waited for EOF instead of replying to one framed message")
        guard waitResult == .completed else { return }

        let payload = try NativeMessageFrame.decode(responseFrame)
        let response = try JSONDecoder().decode(NativeMessageResponse.self, from: payload)
        XCTAssertEqual(response.status, .rejected)
    }

    func testQueuesValidRequestWithoutLaunchingOrFocusingTheApp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = ChromeCompanionQueue(fileURL: directory.appendingPathComponent("pending.json"))
        let host = NativeMessageHost(queue: queue)
        let request = Data("""
        {"version":1,"requestId":"01234567-89AB-CDEF-0123-456789ABCDEF","action":"enqueueDownload","url":"https://youtu.be/example","issuedAtMs":1723651200000}
        """.utf8)

        let response = host.handle(request, now: Date(timeIntervalSince1970: 1_723_651_200))

        XCTAssertEqual(response.status, .queued)
        XCTAssertEqual(response.requestID, "01234567-89AB-CDEF-0123-456789ABCDEF")
        XCTAssertEqual(try queue.dequeue()?.url.absoluteString, "https://youtu.be/example")
    }

    func testRejectsMalformedRequestWithoutLaunchingApp() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = NativeMessageHost(
            queue: ChromeCompanionQueue(fileURL: directory.appendingPathComponent("pending.json"))
        )

        let response = host.handle(Data("not-json".utf8), now: Date(timeIntervalSince1970: 1_723_651_200))

        XCTAssertEqual(response.status, .rejected)
    }

    func testRejectsQueueWriteFailureWithoutLaunchingApp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockingFile = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blockingFile)
        let host = NativeMessageHost(
            queue: ChromeCompanionQueue(fileURL: blockingFile.appendingPathComponent("pending.json"))
        )
        let request = Data("""
        {"version":1,"requestId":"01234567-89AB-CDEF-0123-456789ABCDEF","action":"enqueueDownload","url":"https://youtu.be/example","issuedAtMs":1723651200000}
        """.utf8)

        let response = host.handle(request, now: Date(timeIntervalSince1970: 1_723_651_200))

        XCTAssertEqual(response.status, .rejected)
    }

    func testReportsFullQueueWithoutRemovingExistingRequests() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = ChromeCompanionQueue(fileURL: directory.appendingPathComponent("pending.json"))
        for index in 0..<ChromeCompanionQueue.maximumRequestCount {
            let request = ChromeCompanionRequest(
                requestID: UUID(),
                url: URL(string: "https://soundcloud.com/artist/track-\(index)")!,
                issuedAtMs: 1_723_651_200_000
            )
            XCTAssertEqual(try queue.enqueue(request), .queued)
        }
        let host = NativeMessageHost(queue: queue)
        let request = Data("""
        {"version":1,"requestId":"01234567-89AB-CDEF-0123-456789ABCDEF","action":"enqueueDownload","url":"https://youtu.be/overflow","issuedAtMs":1723651200000}
        """.utf8)

        let response = host.handle(request, now: Date(timeIntervalSince1970: 1_723_651_200))

        XCTAssertEqual(response.status, .full)
        XCTAssertEqual(try queue.entries().count, ChromeCompanionQueue.maximumRequestCount)
    }

    func testFrameRoundTripPreservesPayloadAndRejectsOversizedDeclaration() throws {
        let frame = try NativeMessageFrame.encode(Data("{}".utf8))

        XCTAssertEqual(try NativeMessageFrame.decode(frame), Data("{}".utf8))
        XCTAssertThrowsError(try NativeMessageFrame.decode(Data([0x01, 0x10, 0x00, 0x00])))
    }
}
