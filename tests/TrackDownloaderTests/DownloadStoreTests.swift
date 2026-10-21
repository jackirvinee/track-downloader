import TrackDownloaderCore
import Foundation
import XCTest
@testable import TrackDownloader

@MainActor
final class DownloadStoreTests: XCTestCase {
    /* func testEveryTransferStateMapsToItsPersistentMeterEndpointPresentation() {
        let failure = DownloadFailurePresentation(
            kind: .extractor,
            title: "Download failed",
            message: "The source could not be downloaded.",
            technicalDetails: nil
        )
        let progress = DownloadProgress(
            stage: .downloading,
            fractionCompleted: 0.42,
            detail: "3.2 MiB/s"
        )
        let cases: [(state: DownloadState, fraction: Double?, label: String)] = [
            (.idle, 0, "Ready"),
            (.running(progress), 0.42, "Downloading audio"),
            (.finished(sampleResult()), 1, "Saved"),
            (.failed(failure), 0, "Failed"),
            (.invalidInput("Unsupported link"), 0, "Invalid link"),
            (.cancelled, 0, "Cancelled"),
        ]

        for testCase in cases {
            let presentation = ContentView.transferMeterPresentation(for: testCase.state)

            XCTAssertEqual(presentation.fractionCompleted, testCase.fraction)
            XCTAssertEqual(presentation.stageLabel, testCase.label)
        }
    }

    func testEveryRunningStageMapsToTheMeterEndpointWithoutLosingProgress() {
        let cases: [(stage: DownloadStage, label: String)] = [
            (.validating, "Checking link"),
            (.resolving, "Finding the best source"),
            (.downloading, "Downloading audio"),
            (.processing, "Adding artwork and metadata"),
            (.measuringQuality, "Measuring saved audio"),
        ]

        for (index, testCase) in cases.enumerated() {
            let fraction = Double(index + 1) / 10
            let presentation = ContentView.transferMeterPresentation(
                for: .running(
                    DownloadProgress(
                        stage: testCase.stage,
                        fractionCompleted: fraction,
                        detail: nil
                    )
                )
            )

            XCTAssertEqual(presentation.fractionCompleted, fraction)
            XCTAssertEqual(presentation.stageLabel, testCase.label)
        }
    } */

    func testInvalidLinkSetsDistinctNonRunningState() {
        let service = ControlledDownloadService()
        let store = DownloadStore(service: service)
        store.link = "https://example.com/not-supported"

        store.download()

        XCTAssertEqual(
            store.state,
            .invalidInput("This app supports YouTube and SoundCloud links.")
        )
        XCTAssertEqual(service.sourceURLs, [])
    }

    func testValidRequestPublishesMeaningfulProgressThenFinishes() async {
        let service = ControlledDownloadService()
        let store = DownloadStore(service: service)
        let result = sampleResult()
        store.link = "https://soundcloud.com/artist/night-drive"

        store.download()
        await waitUntil { service.isAwaitingCompletion }

        let resolving = DownloadProgress(stage: .resolving, fractionCompleted: nil, detail: nil)
        service.emit(resolving)
        await waitUntil { store.state == .running(resolving) }

        let downloading = DownloadProgress(stage: .downloading, fractionCompleted: 0.42, detail: "3.2MiB/s · 00:12")
        service.emit(downloading)
        await waitUntil { store.state == .running(downloading) }

        let processing = DownloadProgress(stage: .processing, fractionCompleted: nil, detail: "EmbedThumbnail")
        service.emit(processing)
        await waitUntil { store.state == .running(processing) }

        service.finish(.success(result))
        await waitUntil { store.state == .finished(result) }
        XCTAssertEqual(store.link, "")
    }

    func testTypedFailureRetainsActionablePresentationAndDetails() async {
        let service = ControlledDownloadService()
        let store = DownloadStore(service: service)
        let failure = DownloadFailurePresentation(
            kind: .missingDependency(
                name: "yt-dlp",
                installCommand: "brew install yt-dlp ffmpeg"
            ),
            title: "Missing yt-dlp",
            message: "Install it with Homebrew, then try again.",
            technicalDetails: "brew install yt-dlp ffmpeg"
        )
        store.link = "https://youtu.be/example"

        store.download()
        await waitUntil { service.isAwaitingCompletion }
        service.finish(.failure(failure))
        await waitUntil { store.state == .failed(failure) }

        XCTAssertEqual(store.failure, failure)
    }

    func testArchiveRecoveryCanStartANewLink() async {
        let service = ControlledDownloadService()
        let store = DownloadStore(service: service)
        let archived = DownloadFailurePresentation(
            kind: .alreadyInCollection,
            title: "Previously downloaded",
            message: "No new file was created. This link appears in Track Downloader's download history; check your local collection.",
            technicalDetails: nil
        )
        store.link = "https://soundcloud.com/artist/already-saved"

        store.download()
        await waitUntil { service.isAwaitingCompletion }
        service.finish(.failure(archived))
        await waitUntil { store.state == .failed(archived) }

        store.reset()
        XCTAssertEqual(store.state, .idle)
        XCTAssertEqual(store.link, "")

        store.link = "https://soundcloud.com/artist/new-track"
        store.download()
        await waitUntil { service.sourceURLs.count == 2 }

        XCTAssertEqual(
            service.sourceURLs,
            [
                URL(string: "https://soundcloud.com/artist/already-saved")!,
                URL(string: "https://soundcloud.com/artist/new-track")!
            ]
        )
    }

    /* func testCollectionRecoveryUsesNeutralOuterHardwarePresentation() {
        let failure = DownloadFailurePresentation(
            kind: .alreadyInCollection,
            title: "Previously downloaded",
            message: "No new file was created. This link appears in Track Downloader's download history; check your local collection.",
            technicalDetails: nil
        )

        let presentation = ContentView.hardwarePresentation(for: .failed(failure))

        XCTAssertEqual(presentation.plate, "Track Downloader / DOWNLOAD HISTORY")
        XCTAssertEqual(presentation.status, "CHECK COLLECTION")
        guard case .neutral = presentation.tone else {
            return XCTFail("Archive recovery must not use the failure hardware tone")
        }
    } */

    func testSecondRequestIsIgnoredWhileFirstJobIsActive() async {
        let service = ControlledDownloadService()
        let store = DownloadStore(service: service)
        store.link = "https://soundcloud.com/artist/first"

        store.download()
        await waitUntil { service.isAwaitingCompletion }
        store.link = "https://soundcloud.com/artist/second"
        store.download()

        XCTAssertEqual(service.sourceURLs.count, 1)
        XCTAssertEqual(store.state, .running(DownloadProgress(stage: .validating, fractionCompleted: nil, detail: nil)))
    }

    func testCancellationReturnsCancelledAndIgnoresLateCompletion() async {
        let service = ControlledDownloadService()
        let store = DownloadStore(service: service)
        store.link = "https://soundcloud.com/artist/track"

        store.download()
        await waitUntil { service.isAwaitingCompletion }
        store.cancel()

        XCTAssertEqual(service.cancelCount, 1)
        XCTAssertEqual(store.state, .cancelled)

        service.finish(.success(sampleResult()))
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(store.state, .cancelled)
    }

    func testRetryRerunsTheSameNormalizedURL() async {
        let service = ControlledDownloadService()
        let store = DownloadStore(service: service)
        let sourceURL = "https://soundcloud.com/artist/track"
        store.link = sourceURL
        let failure = DownloadFailurePresentation(
            kind: .extractor,
            title: "Download failed",
            message: "Video unavailable",
            technicalDetails: "ERROR: Video unavailable"
        )

        store.download()
        await waitUntil { service.isAwaitingCompletion }
        service.finish(.failure(failure))
        await waitUntil { store.state == .failed(failure) }

        store.retry()
        await waitUntil { service.isAwaitingCompletion }
        service.finish(.success(sampleResult()))
        await waitUntil {
            if case .finished = store.state { return true }
            return false
        }

        XCTAssertEqual(service.sourceURLs, [URL(string: sourceURL)!, URL(string: sourceURL)!])
    }

    func testResetClearsLinkAndReturnsIdle() async {
        let service = ControlledDownloadService()
        let store = DownloadStore(service: service)
        store.link = "https://soundcloud.com/artist/track"

        store.download()
        await waitUntil { service.isAwaitingCompletion }
        store.reset()

        XCTAssertEqual(store.state, .idle)
        XCTAssertEqual(store.link, "")
        XCTAssertEqual(service.cancelCount, 1)
    }

    private func sampleResult() -> DownloadResult {
        let fileURL = URL(fileURLWithPath: "/tmp/Artist - Night Drive.opus")
        return DownloadResult(
            fileURL: fileURL,
            metadata: TrackMetadata(title: "Night Drive"),
            quality: AudioQuality(
                fileURL: fileURL,
                codec: "opus",
                kbps: 192,
                sampleRateHz: 48_000,
                verdict: .good
            )
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

private final class ControlledDownloadService: DownloadServicing, @unchecked Sendable {
    let outputDirectory = URL(fileURLWithPath: "/tmp/track-downloader-store-tests", isDirectory: true)

    private let lock = NSLock()
    private var progressHandler: (@Sendable (DownloadProgress) -> Void)?
    private var continuation: CheckedContinuation<DownloadResult, Error>?
    private var recordedSourceURLs: [URL] = []
    private var recordedCancelCount = 0

    var sourceURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSourceURLs
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCancelCount
    }

    var isAwaitingCompletion: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    func download(
        sourceURL: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        withLock {
            recordedSourceURLs.append(sourceURL)
            progressHandler = onProgress
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        recordedCancelCount += 1
        lock.unlock()
    }

    func emit(_ progress: DownloadProgress) {
        lock.lock()
        let handler = progressHandler
        lock.unlock()
        handler?(progress)
    }

    func finish(_ result: Result<DownloadResult, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
