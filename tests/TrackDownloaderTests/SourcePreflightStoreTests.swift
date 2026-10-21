import Foundation
import XCTest
@testable import TrackDownloader
@testable import TrackDownloaderCore

@MainActor
final class SourcePreflightStoreTests: XCTestCase {
    func testEmptyAndUnsupportedLinksStayLocalWithoutStartingPreflight() async {
        let service = ControlledPreflightService()
        let sleeper = ControlledPreflightSleeper()
        let store = makeStore(service: service, sleeper: sleeper)

        store.sourceChanged("")
        XCTAssertEqual(store.state, .idle)

        store.sourceChanged("https://example.com/not-supported")
        XCTAssertEqual(store.state, .invalidLink("This app supports YouTube and SoundCloud links."))
        XCTAssertEqual(service.invocationCount, 0)
        let requestedNanoseconds = await sleeper.requestedNanoseconds
        XCTAssertEqual(requestedNanoseconds, [])
    }

    func testValidLinkWaitsFourHundredMillisecondsBeforeInspection() async {
        let service = ControlledPreflightService()
        let sleeper = ControlledPreflightSleeper()
        let store = makeStore(service: service, sleeper: sleeper)

        store.sourceChanged("https://soundcloud.com/artist/track")
        await eventually { await sleeper.requestedNanoseconds == [400_000_000] }
        XCTAssertEqual(service.invocationCount, 0)

        await sleeper.resumeNext()
        await eventually { store.state == .checking }
        XCTAssertEqual(service.invocationCount, 1)
    }

    func testReplacingALinkDuringDebounceInspectsOnlyTheReplacement() async {
        let service = ControlledPreflightService()
        let sleeper = ControlledPreflightSleeper()
        let store = makeStore(service: service, sleeper: sleeper)
        let first = "https://soundcloud.com/artist/first"
        let second = "https://soundcloud.com/artist/second"

        store.sourceChanged(first)
        await eventually { await sleeper.requestedNanoseconds.count == 1 }
        store.sourceChanged(second)
        await eventually { await sleeper.requestedNanoseconds.count == 2 }

        await sleeper.resumeNext()
        await Task.yield()
        XCTAssertEqual(service.invocationCount, 0)

        await sleeper.resumeNext()
        await eventually { service.invocationCount == 1 }
        XCTAssertEqual(service.sourceURLs, [URL(string: second)!])
    }

    func testReplacingActiveInspectionCancelsServiceAndDebouncesReplacement() async {
        let service = ControlledPreflightService()
        let sleeper = ControlledPreflightSleeper()
        let store = makeStore(service: service, sleeper: sleeper)

        store.sourceChanged("https://soundcloud.com/artist/first")
        await eventually { await sleeper.requestedNanoseconds.count == 1 }
        await sleeper.resumeNext()
        await eventually { service.invocationCount == 1 }

        store.sourceChanged("https://soundcloud.com/artist/second")
        XCTAssertEqual(service.cancelCount, 2)
        await eventually { await sleeper.requestedNanoseconds.count == 2 }
        await sleeper.resumeNext()
        await eventually { service.invocationCount == 2 }
    }

    func testLateCancellationIgnoringResponseCannotReplaceNewerResult() async {
        let service = ControlledPreflightService()
        let sleeper = ControlledPreflightSleeper()
        let store = makeStore(service: service, sleeper: sleeper)
        let firstResult = result(title: "First")
        let secondResult = result(title: "Second")

        store.sourceChanged("https://soundcloud.com/artist/first")
        await eventually { await sleeper.requestedNanoseconds.count == 1 }
        await sleeper.resumeNext()
        await eventually { service.invocationCount == 1 }

        store.sourceChanged("https://soundcloud.com/artist/second")
        await eventually { await sleeper.requestedNanoseconds.count == 2 }
        await sleeper.resumeNext()
        await eventually { service.invocationCount == 2 }

        service.finish(secondResult, at: 1)
        await eventually { store.state == .ready(secondResult) }
        service.finish(firstResult, at: 0)
        await Task.yield()
        XCTAssertEqual(store.state, .ready(secondResult))
    }

    func testInvalidReplacementPublishesImmediatelyAndRejectsLateReadyResult() async {
        let service = ControlledPreflightService()
        let sleeper = ControlledPreflightSleeper()
        let store = makeStore(service: service, sleeper: sleeper)

        store.sourceChanged("https://soundcloud.com/artist/first")
        await eventually { await sleeper.requestedNanoseconds.count == 1 }
        await sleeper.resumeNext()
        await eventually { service.invocationCount == 1 }

        store.sourceChanged("not a link")
        XCTAssertEqual(store.state, .invalidLink("Paste a valid YouTube or SoundCloud link."))
        service.finish(result(title: "Late"), at: 0)
        await Task.yield()
        XCTAssertEqual(store.state, .invalidLink("Paste a valid YouTube or SoundCloud link."))
    }

    func testCheckAgainRetriesLastURLWithoutDebounce() async {
        let service = ControlledPreflightService()
        let sleeper = ControlledPreflightSleeper()
        let store = makeStore(service: service, sleeper: sleeper)
        let source = URL(string: "https://soundcloud.com/artist/track")!

        store.sourceChanged(source.absoluteString)
        await eventually { await sleeper.requestedNanoseconds.count == 1 }
        await sleeper.resumeNext()
        await eventually { service.invocationCount == 1 }
        service.finishError(SourcePreflightServiceError.transient, at: 0)
        await eventually { store.state == .unavailable(SourcePreflightServiceError.transient.message) }

        store.checkAgain()
        XCTAssertEqual(store.state, .checking)

        await eventually { service.invocationCount == 2 }
        XCTAssertEqual(service.sourceURLs, [source, source])
        let requestedNanoseconds = await sleeper.requestedNanoseconds
        XCTAssertEqual(requestedNanoseconds, [400_000_000])
    }

    func testSameNormalizedReadyURLDoesNotContactPlatformAgain() async {
        let service = ControlledPreflightService()
        let sleeper = ControlledPreflightSleeper()
        let store = makeStore(service: service, sleeper: sleeper)
        let source = "https://soundcloud.com/artist/track"
        let ready = result(title: "Ready")

        store.sourceChanged(source)
        await eventually { await sleeper.requestedNanoseconds.count == 1 }
        await sleeper.resumeNext()
        await eventually { service.invocationCount == 1 }
        service.finish(ready, at: 0)
        await eventually { store.state == .ready(ready) }

        store.sourceChanged(source)
        await Task.yield()

        XCTAssertEqual(service.invocationCount, 1)
        XCTAssertEqual(store.state, .ready(ready))
    }

    func testPreparingForDownloadCancelsLateInspectionAndRetainsReadyCard() async {
        let service = ControlledPreflightService()
        let sleeper = ControlledPreflightSleeper()
        let store = makeStore(service: service, sleeper: sleeper)
        let retained = result(title: "Retained")

        store.sourceChanged("https://soundcloud.com/artist/retained")
        await eventually { await sleeper.requestedNanoseconds.count == 1 }
        await sleeper.resumeNext()
        await eventually { service.invocationCount == 1 }
        service.finish(retained, at: 0)
        await eventually { store.state == .ready(retained) }

        store.checkAgain()
        await eventually { service.invocationCount == 2 }
        store.prepareForDownload()

        XCTAssertEqual(service.cancelCount, 3)
        service.finish(result(title: "Late"), at: 1)
        await Task.yield()
        XCTAssertEqual(store.state, .ready(retained))
    }

    func testReadyPreflightDoesNotChangeDownloadStoreOrInvokeDownloadService() async {
        let preflightService = ControlledPreflightService()
        let sleeper = ControlledPreflightSleeper()
        let preflightStore = makeStore(service: preflightService, sleeper: sleeper)
        let downloadService = DownloadServiceRecorder()
        let downloadStore = DownloadStore(service: downloadService)
        let ready = result(title: "Independent")

        preflightStore.sourceChanged("https://soundcloud.com/artist/track")
        await eventually { await sleeper.requestedNanoseconds.count == 1 }
        await sleeper.resumeNext()
        await eventually { preflightService.invocationCount == 1 }
        preflightService.finish(ready, at: 0)
        await eventually { preflightStore.state == .ready(ready) }

        XCTAssertEqual(downloadStore.state, .idle)
        XCTAssertEqual(downloadService.sourceURLs, [])
    }

    private func makeStore(
        service: ControlledPreflightService,
        sleeper: ControlledPreflightSleeper
    ) -> SourcePreflightStore {
        SourcePreflightStore(
            service: service,
            sleep: { nanoseconds in await sleeper.sleep(nanoseconds) }
        )
    }

    private func result(title: String) -> SourcePreflightResult {
        SourcePreflightResult(
            title: title,
            uploader: nil,
            durationSeconds: nil,
            selectedAudio: .init(codec: "opus", bitrateKbps: 192, sampleRateHz: 48_000),
            assessment: .compatibleExportLikely
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 where !(await condition()) {
            await Task.yield()
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, file: file, line: line)
    }
}

private final class ControlledPreflightService: SourcePreflightServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []
    private var recordedCancelCount = 0
    private var continuations: [CheckedContinuation<SourcePreflightResult, Error>] = []

    var invocationCount: Int { withLock { recordedURLs.count } }
    var sourceURLs: [URL] { withLock { recordedURLs } }
    var cancelCount: Int { withLock { recordedCancelCount } }

    func inspect(sourceURL: URL) async throws -> SourcePreflightResult {
        withLock { recordedURLs.append(sourceURL) }
        return try await withCheckedThrowingContinuation { continuation in
            withLock { continuations.append(continuation) }
        }
    }

    func cancel() {
        withLock { recordedCancelCount += 1 }
    }

    func finish(_ result: SourcePreflightResult, at index: Int) {
        withLock { continuations[index] }.resume(returning: result)
    }

    func finishError(_ error: Error, at index: Int) {
        withLock { continuations[index] }.resume(throwing: error)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private actor ControlledPreflightSleeper {
    private var requested: [UInt64] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var requestedNanoseconds: [UInt64] { requested }

    func sleep(_ nanoseconds: UInt64) async {
        requested.append(nanoseconds)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        continuations.removeFirst().resume()
    }
}

private final class DownloadServiceRecorder: DownloadServicing, @unchecked Sendable {
    let outputDirectory = URL(fileURLWithPath: "/tmp/track-downloader-preflight-isolation", isDirectory: true)
    private(set) var sourceURLs: [URL] = []

    func download(
        sourceURL: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        sourceURLs.append(sourceURL)
        fatalError("Preflight must not start DownloadStore")
    }

    func cancel() {}
}
