import Foundation
import TrackDownloaderChromeCompanion
import TrackDownloaderCore
import XCTest
@testable import TrackDownloader

@MainActor
final class ChromeQueueStoreTests: XCTestCase {
    func testPastedLinkPersistsAndChecksWithoutDownloading() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let preparation = QueuePreflightRecorder()
        let downloader = QueueDownloadRecorder(outcomes: [])
        let store = ChromeQueueStore(queue: fixture.queue,
            preflightService: QueuePreflightRecorder(), downloadService: downloader,
            preparationService: preparation)
        store.enablePreparation()
        XCTAssertTrue(store.enqueueLink("https://soundcloud.com/example/new-pasted-track"))
        let checked = await waitUntil { store.preparations.count == 3 && store.preparations.values.allSatisfy {
            if case .ready = $0 { return true }; return false
        } }
        XCTAssertTrue(checked)
        XCTAssertEqual(try fixture.queue.entries().count, 3)
        XCTAssertEqual(downloader.sourceURLs, [])
        XCTAssertTrue(store.enqueueLink("https://soundcloud.com/example/new-pasted-track"))
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertNotNil(store.inputMessage)
        XCTAssertFalse(store.enqueueLink("https://example.com/unsupported"))
        XCTAssertEqual(store.entries.count, 3)
    }

    func testExplicitRequestsWaitSequentiallyAndPasteRemainsAvailableDuringDownload() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let downloader = ControlledQueueDownloader()
        let store = ChromeQueueStore(queue: fixture.queue,
            preflightService: QueuePreflightRecorder(), downloadService: downloader)
        store.download(fixture.requests[0].requestID)
        let started = await waitUntil { downloader.isWaiting }
        XCTAssertTrue(started)
        store.download(fixture.requests[1].requestID)
        XCTAssertEqual(store.requestedDownloads, [fixture.requests[1].requestID])
        XCTAssertTrue(store.enqueueLink("https://soundcloud.com/example/another-track"))
        XCTAssertEqual(try fixture.queue.entries().count, 3)
        XCTAssertTrue(store.isRunning)
        store.cancel()
        XCTAssertEqual(store.requestedDownloads, [])
        XCTAssertEqual(try fixture.queue.entries().count, 3)
        let restored = ChromeQueueStore(queue: fixture.queue,
            preflightService: QueuePreflightRecorder(), downloadService: downloader)
        XCTAssertEqual(restored.entries.count, 3)
        XCTAssertFalse(restored.isRunning)
    }

    func testLoadingQueueDoesNotInspectOrDownloadUntilUserRequestsIt() throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let preflight = QueuePreflightRecorder()
        let downloader = QueueDownloadRecorder(outcomes: [])

        let store = ChromeQueueStore(
            queue: fixture.queue,
            preflightService: preflight,
            downloadService: downloader
        )

        XCTAssertEqual(store.entries.map(\.id), fixture.requests.map(\.requestID))
        XCTAssertEqual(preflight.sourceURLs, [])
        XCTAssertEqual(downloader.sourceURLs, [])
    }

    func testDownloadAllContinuesAfterFailureAndRemovesOnlySuccessfulItem() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let preflight = QueuePreflightRecorder()
        let firstFailure = DownloadFailurePresentation(
            kind: .extractor,
            title: "Source could not be downloaded",
            message: "The first source is unavailable.",
            technicalDetails: nil
        )
        let downloader = QueueDownloadRecorder(outcomes: [
            .failure(firstFailure),
            .success(sampleResult()),
        ])
        let store = ChromeQueueStore(
            queue: fixture.queue,
            preflightService: preflight,
            downloadService: downloader
        )

        store.downloadAll()
        let batchFinished = await waitUntil { !store.isRunning && downloader.sourceURLs.count == 2 }
        XCTAssertTrue(batchFinished)

        XCTAssertEqual(preflight.sourceURLs, fixture.requests.map(\.url))
        XCTAssertEqual(downloader.sourceURLs, fixture.requests.map(\.url))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, fixture.requests.first?.requestID)
        XCTAssertEqual(store.entries.first?.status, .failed("The first source is unavailable."))
        XCTAssertEqual(store.lastCompletedResult, sampleResult())
    }

    func testCancelStopsBatchAndRetainsActiveAndUnfinishedItems() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let preflight = QueuePreflightRecorder()
        let downloader = ControlledQueueDownloader()
        let store = ChromeQueueStore(
            queue: fixture.queue,
            preflightService: preflight,
            downloadService: downloader
        )

        store.downloadAll()
        let downloadStarted = await waitUntil { downloader.isWaiting }
        XCTAssertTrue(downloadStarted)
        store.cancel()
        let batchCancelled = await waitUntil { !store.isRunning }
        XCTAssertTrue(batchCancelled)

        XCTAssertEqual(downloader.cancelCount, 1)
        XCTAssertEqual(store.entries.map(\.id), fixture.requests.map(\.requestID))
        XCTAssertEqual(try fixture.queue.entries().map(\.id), fixture.requests.map(\.requestID))
    }

    func testClearWaitingDuringDownloadKeepsActiveItem() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanup() }
        let downloader = ControlledQueueDownloader()
        let store = ChromeQueueStore(
            queue: fixture.queue,
            preflightService: QueuePreflightRecorder(),
            downloadService: downloader
        )

        store.download(fixture.requests[0].requestID)
        let downloadStarted = await waitUntil { downloader.isWaiting }
        XCTAssertTrue(downloadStarted)
        store.clearWaiting()

        XCTAssertEqual(store.entries.map(\.id), [fixture.requests[0].requestID])
        store.cancel()
        let downloadCancelled = await waitUntil { !store.isRunning }
        XCTAssertTrue(downloadCancelled)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<500 where !condition() {
            await Task.yield()
        }
        return condition()
    }
}

private struct QueueFixture {
    let directory: URL
    let queue: ChromeCompanionQueue
    let requests: [ChromeCompanionRequest]

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        queue = ChromeCompanionQueue(fileURL: directory.appendingPathComponent("pending.json"))
        requests = [
            ChromeCompanionRequest(
                requestID: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
                url: URL(string: "https://soundcloud.com/artist/first")!,
                issuedAtMs: 1_723_651_200_000
            ),
            ChromeCompanionRequest(
                requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                url: URL(string: "https://soundcloud.com/artist/second")!,
                issuedAtMs: 1_723_651_200_100
            ),
        ]
        for request in requests {
            _ = try queue.enqueue(request)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class QueuePreflightRecorder: SourcePreflightServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    var sourceURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    func inspect(sourceURL: URL) async throws -> SourcePreflightResult {
        record(sourceURL)
        return SourcePreflightResult(
            title: "Night Drive",
            uploader: "Example Artist",
            durationSeconds: 240,
            selectedAudio: SelectedSourceAudio(codec: "opus", bitrateKbps: 192, sampleRateHz: 48_000),
            assessment: .compatibleExportLikely
        )
    }

    private func record(_ sourceURL: URL) {
        lock.lock()
        recordedURLs.append(sourceURL)
        lock.unlock()
    }

    func cancel() {}
}

private final class QueueDownloadRecorder: DownloadServicing, @unchecked Sendable {
    enum Outcome {
        case success(DownloadResult)
        case failure(Error)
    }

    let outputDirectory = URL(fileURLWithPath: "/tmp/track-downloader-queue-tests", isDirectory: true)
    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var recordedURLs: [URL] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    var sourceURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    func download(
        sourceURL: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        let outcome = recordAndTakeOutcome(sourceURL)
        onProgress(DownloadProgress(stage: .downloading, fractionCompleted: 0.5, detail: nil))
        switch outcome {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    private func recordAndTakeOutcome(_ sourceURL: URL) -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        recordedURLs.append(sourceURL)
        return outcomes.removeFirst()
    }

    func cancel() {}
}

private final class ControlledQueueDownloader: DownloadServicing, @unchecked Sendable {
    let outputDirectory = URL(fileURLWithPath: "/tmp/track-downloader-queue-tests", isDirectory: true)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DownloadResult, Error>?
    private(set) var cancelCount = 0

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    func download(
        sourceURL: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        onProgress(DownloadProgress(stage: .downloading, fractionCompleted: 0.25, detail: nil))
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelCount += 1
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

private func sampleResult() -> DownloadResult {
    let fileURL = URL(fileURLWithPath: "/tmp/track-downloader-queue-tests/Night Drive.opus")
    return DownloadResult(
        fileURL: fileURL,
        metadata: TrackMetadata(title: "Night Drive", artist: "Example Artist", album: nil),
        quality: AudioQuality(
            fileURL: fileURL,
            codec: "opus",
            kbps: 192,
            sampleRateHz: 48_000,
            verdict: .good
        )
    )
}
