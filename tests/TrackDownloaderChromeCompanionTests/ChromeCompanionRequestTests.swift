import Foundation
import XCTest
@testable import TrackDownloaderChromeCompanion

final class ChromeCompanionRequestTests: XCTestCase {
    func testDecodesSupportedVersionOneRequest() throws {
        let request = try ChromeCompanionRequest.decode(
            Data("""
            {"version":1,"requestId":"01234567-89AB-CDEF-0123-456789ABCDEF","action":"enqueueDownload","url":"https://www.youtube.com/watch?v=example","issuedAtMs":1723651200000}
            """.utf8),
            now: Date(timeIntervalSince1970: 1_723_651_200)
        )

        XCTAssertEqual(request.requestID.uuidString, "01234567-89AB-CDEF-0123-456789ABCDEF")
        XCTAssertEqual(request.action, .enqueueDownload)
        XCTAssertEqual(request.url.absoluteString, "https://www.youtube.com/watch?v=example")
    }

    func testRejectsUnsupportedHostAndOversizedEnvelope() {
        let unsupported = Data("""
        {"version":1,"requestId":"01234567-89AB-CDEF-0123-456789ABCDEF","action":"enqueueDownload","url":"https://example.com/track","issuedAtMs":1723651200000}
        """.utf8)

        XCTAssertThrowsError(try ChromeCompanionRequest.decode(unsupported))
        XCTAssertThrowsError(try ChromeCompanionRequest.decode(Data(repeating: 0x61, count: 4_097)))
    }

    func testDecodesVersionTwoRequestWithBoundedDisplayMetadata() throws {
        let request = try ChromeCompanionRequest.decode(
            Data("""
            {"version":2,"requestId":"01234567-89AB-CDEF-0123-456789ABCDEF","action":"enqueueDownload","url":"https://www.youtube.com/watch?v=example#comments","issuedAtMs":1723651200000,"metadata":{"title":"  Night   Drive  ","creator":" Example Artist ","platform":"youtube"}}
            """.utf8),
            now: Date(timeIntervalSince1970: 1_723_651_200)
        )

        XCTAssertEqual(request.url.absoluteString, "https://www.youtube.com/watch?v=example")
        XCTAssertEqual(request.metadata?.title, "Night Drive")
        XCTAssertEqual(request.metadata?.creator, "Example Artist")
        XCTAssertEqual(request.metadata?.platform, .youtube)
    }

    func testRejectsOversizedOrHostMismatchedDisplayMetadata() {
        let oversizedTitle = String(repeating: "x", count: 161)
        let oversized = Data("""
        {"version":2,"requestId":"01234567-89AB-CDEF-0123-456789ABCDEF","action":"enqueueDownload","url":"https://youtu.be/example","issuedAtMs":1723651200000,"metadata":{"title":"\(oversizedTitle)","creator":null,"platform":"youtube"}}
        """.utf8)
        let mismatchedPlatform = Data("""
        {"version":2,"requestId":"01234567-89AB-CDEF-0123-456789ABCDEF","action":"enqueueDownload","url":"https://soundcloud.com/artist/track","issuedAtMs":1723651200000,"metadata":{"title":"Night Drive","creator":"Example Artist","platform":"youtube"}}
        """.utf8)

        XCTAssertThrowsError(try ChromeCompanionRequest.decode(oversized, now: Date(timeIntervalSince1970: 1_723_651_200)))
        XCTAssertThrowsError(try ChromeCompanionRequest.decode(mismatchedPlatform, now: Date(timeIntervalSince1970: 1_723_651_200)))
    }

    func testRejectsSupportedHostsThatAreNotIndividualTrackPages() {
        let youtubeSearch = Data("""
        {"version":1,"requestId":"01234567-89AB-CDEF-0123-456789ABCDEF","action":"enqueueDownload","url":"https://www.youtube.com/results?search_query=night","issuedAtMs":1723651200000}
        """.utf8)
        let soundCloudDiscover = Data("""
        {"version":1,"requestId":"01234567-89AB-CDEF-0123-456789ABCDEF","action":"enqueueDownload","url":"https://soundcloud.com/discover/sets/charts-top:all-music","issuedAtMs":1723651200000}
        """.utf8)

        XCTAssertThrowsError(try ChromeCompanionRequest.decode(youtubeSearch, now: Date(timeIntervalSince1970: 1_723_651_200)))
        XCTAssertThrowsError(try ChromeCompanionRequest.decode(soundCloudDiscover, now: Date(timeIntervalSince1970: 1_723_651_200)))
    }

    func testQueueDeduplicatesAndDequeuesPersistedRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = ChromeCompanionQueue(fileURL: directory.appendingPathComponent("pending.json"))
        let request = ChromeCompanionRequest(
            requestID: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
            url: URL(string: "https://soundcloud.com/artist/track")!,
            issuedAtMs: 1_723_651_200_000
        )

        XCTAssertEqual(try queue.enqueue(request), .queued)
        XCTAssertEqual(try queue.enqueue(request), .duplicate)
        XCTAssertEqual(try queue.dequeue(), request)
        XCTAssertNil(try queue.dequeue())
    }

    func testQueueDeduplicatesCanonicalURLAcrossDifferentRequestIDs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = ChromeCompanionQueue(fileURL: directory.appendingPathComponent("pending.json"))
        let first = ChromeCompanionRequest(
            requestID: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
            url: URL(string: "https://www.youtube.com/watch?v=example")!,
            issuedAtMs: 1_723_651_200_000
        )
        let second = ChromeCompanionRequest(
            requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            url: URL(string: "https://www.youtube.com/watch?v=example")!,
            issuedAtMs: 1_723_651_200_100
        )

        XCTAssertEqual(try queue.enqueue(first), .queued)
        XCTAssertEqual(try queue.enqueue(second), .duplicate)
        XCTAssertEqual(try queue.entries().map(\.request.requestID), [first.requestID])
    }

    func testQueuePersistsFailureAndClearsOnlyWaitingEntries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueURL = directory.appendingPathComponent("pending.json")
        let queue = ChromeCompanionQueue(fileURL: queueURL)
        let first = ChromeCompanionRequest(
            requestID: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
            url: URL(string: "https://soundcloud.com/artist/first")!,
            issuedAtMs: 1_723_651_200_000
        )
        let second = ChromeCompanionRequest(
            requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            url: URL(string: "https://soundcloud.com/artist/second")!,
            issuedAtMs: 1_723_651_200_100
        )
        XCTAssertEqual(try queue.enqueue(first), .queued)
        XCTAssertEqual(try queue.enqueue(second), .queued)

        try queue.markFailed(requestID: second.requestID, message: "This source is unavailable.")
        let reloaded = ChromeCompanionQueue(fileURL: queueURL)
        XCTAssertEqual(try reloaded.entries().last?.status, .failed("This source is unavailable."))

        XCTAssertEqual(try reloaded.clearWaiting(excluding: first.requestID), 1)
        XCTAssertEqual(try reloaded.entries().map(\.request.requestID), [first.requestID])
    }

    func testQueueRefusesUnsupportedConstructedRequestAndOversizedQueueFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueURL = directory.appendingPathComponent("pending.json")
        let queue = ChromeCompanionQueue(fileURL: queueURL)
        let unsupported = ChromeCompanionRequest(
            requestID: UUID(),
            url: URL(string: "https://example.com/track")!,
            issuedAtMs: 1_723_651_200_000
        )

        XCTAssertThrowsError(try queue.enqueue(unsupported))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 300_000).write(to: queueURL)
        XCTAssertThrowsError(try queue.entries())
    }
}
