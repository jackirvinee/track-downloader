import Foundation
import XCTest
@testable import TrackDownloader

@MainActor
final class UpdateStoreTests: XCTestCase {
    func testInstalledVersionTextIncludesReleaseAndBuildIdentifiers() {
        let store = UpdateStore(
            checker: ControlledUpdateChecker(),
            installedVersionProvider: { "1.0.0" },
            installedBuildProvider: { "20260902.1" }
        )

        XCTAssertEqual(store.installedVersionText, "Version 1.0.0 (Build 20260902.1)")
    }

    func testInstalledVersionTextReportsAnUnavailableBundleVersionTruthfully() {
        let store = UpdateStore(
            checker: ControlledUpdateChecker(),
            installedVersionProvider: { nil }
        )

        XCTAssertEqual(store.installedVersionText, "Version unavailable")
    }

    #if DEBUG
    func testFixtureShowsTheCurrentUserVisibleBuildIdentifier() {
        let store = UpdateStore.fixture(status: .idle)

        XCTAssertEqual(
            store.installedVersionText,
            "Version 1.1.0 (Build 20261002.4)"
        )
    }
    #endif

    func testAutomaticCheckPublishesCheckingWithoutWaitingThenShowsAvailableRelease() async {
        let checker = ControlledUpdateChecker()
        let store = makeStore(checker: checker)

        store.beginAutomaticCheck()

        XCTAssertEqual(store.status, .checking)
        await eventually { await checker.invocationCount == 1 }
        let release = sampleRelease(version: "1.1.0")
        await checker.resumeNext(with: .updateAvailable(release))
        await eventually { store.status == .available(release) }
    }

    func testAutomaticFailureReturnsToIdleWithoutFailurePresentation() async {
        let checker = ControlledUpdateChecker()
        let store = makeStore(checker: checker)

        store.beginAutomaticCheck()
        await eventually { await checker.invocationCount == 1 }
        await checker.resumeNext(throwing: .networkUnavailable)

        await eventually { store.status == .idle }
    }

    func testRepeatedAutomaticChecksStartOnlyOneRequest() async {
        let checker = ControlledUpdateChecker()
        let store = makeStore(checker: checker)

        store.beginAutomaticCheck()
        store.beginAutomaticCheck()

        await eventually { await checker.invocationCount == 1 }
        let invocationCount = await checker.invocationCount
        XCTAssertEqual(invocationCount, 1)
        await checker.resumeNext(with: .upToDate)
        await eventually { store.status == .upToDate }
    }

    func testManualCheckShowsUpToDateAfterSuccessfulComparison() async {
        let checker = ControlledUpdateChecker()
        let store = makeStore(checker: checker)

        store.beginManualCheck()

        XCTAssertEqual(store.status, .checking)
        await eventually { await checker.invocationCount == 1 }
        await checker.resumeNext(with: .upToDate)
        await eventually { store.status == .upToDate }
    }

    func testManualFailuresUseActionableFixedMessages() async {
        let cases: [(UpdateCheckError, String)] = [
            (.noPublicRelease, "No public release is available yet. Try again later."),
            (.rateLimited, "GitHub is temporarily limiting update checks. Try again later."),
            (.networkUnavailable, "Couldn't check for updates. Check your connection and try again."),
            (.invalidInstalledVersion, "This build has no valid version number."),
            (.invalidResponse, "Couldn't read the latest release information. Try again later.")
        ]

        for (error, message) in cases {
            let checker = ControlledUpdateChecker()
            let store = makeStore(checker: checker)
            store.beginManualCheck()
            await eventually { await checker.invocationCount == 1 }
            await checker.resumeNext(throwing: error)
            await eventually { store.status == .manualFailure(message) }
        }
    }

    func testStaleCancelledManualCheckCannotOverwriteLaterResult() async {
        let checker = ControlledUpdateChecker()
        let store = makeStore(checker: checker)

        store.beginManualCheck()
        await eventually { await checker.invocationCount == 1 }
        store.beginManualCheck()
        await eventually { await checker.invocationCount == 2 }

        await checker.resume(at: 1, with: .upToDate)
        await eventually { store.status == .upToDate }
        await checker.resume(at: 0, throwing: .networkUnavailable)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(store.status, .upToDate)
    }

    func testDismissedVersionIsSuppressedOnlyForAutomaticChecks() async {
        let suite = "UpdateStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let offeredRelease = sampleRelease(version: "1.1.0")
        let firstChecker = ControlledUpdateChecker()
        let firstStore = makeStore(checker: firstChecker, defaults: defaults)
        firstStore.beginAutomaticCheck()
        await eventually { await firstChecker.invocationCount == 1 }
        await firstChecker.resumeNext(with: .updateAvailable(offeredRelease))
        await eventually { firstStore.status == .available(offeredRelease) }

        firstStore.dismissAvailableUpdate()
        XCTAssertEqual(firstStore.status, .idle)
        XCTAssertEqual(defaults.string(forKey: "TrackDownloaderDismissedUpdateVersion"), "1.1.0")

        let secondChecker = ControlledUpdateChecker()
        let secondStore = makeStore(checker: secondChecker, defaults: defaults)
        secondStore.beginAutomaticCheck()
        await eventually { await secondChecker.invocationCount == 1 }
        await secondChecker.resumeNext(with: .updateAvailable(offeredRelease))
        await eventually { secondStore.status == .idle }

        secondStore.beginManualCheck()
        await eventually { await secondChecker.invocationCount == 2 }
        await secondChecker.resumeNext(with: .updateAvailable(offeredRelease))
        await eventually { secondStore.status == .available(offeredRelease) }

        let laterRelease = sampleRelease(version: "1.2.0")
        let thirdChecker = ControlledUpdateChecker()
        let thirdStore = makeStore(checker: thirdChecker, defaults: defaults)
        thirdStore.beginAutomaticCheck()
        await eventually { await thirdChecker.invocationCount == 1 }
        await thirdChecker.resumeNext(with: .updateAvailable(laterRelease))
        await eventually { thirdStore.status == .available(laterRelease) }
    }

    private func makeStore(
        checker: any UpdateChecking,
        defaults: UserDefaults = .standard
    ) -> UpdateStore {
        UpdateStore(
            checker: checker,
            installedVersionProvider: { "1.0.0" },
            installedBuildProvider: { "20260902.1" },
            defaults: defaults
        )
    }

    private func sampleRelease(version: String) -> UpdateRelease {
        UpdateRelease(
            version: StableVersion(releaseTag: "v\(version)")!,
            notes: "Safer downloads and clearer errors.",
            pageURL: URL(string: "https://github.com/jackirvinee/track-downloader/releases/tag/v\(version)")!
        )
    }

    private func eventually(
        timeoutIterations: Int = 100,
        _ condition: @escaping () async -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied")
    }
}

private actor ControlledUpdateChecker: UpdateChecking {
    private var continuations: [CheckedContinuation<UpdateCheckResult, Error>] = []
    private(set) var invocationCount = 0

    func check(installedVersion: String) async throws -> UpdateCheckResult {
        invocationCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext(with result: UpdateCheckResult) {
        continuations.removeFirst().resume(returning: result)
    }

    func resumeNext(throwing error: UpdateCheckError) {
        continuations.removeFirst().resume(throwing: error)
    }

    func resume(at index: Int, with result: UpdateCheckResult) {
        continuations.remove(at: index).resume(returning: result)
    }

    func resume(at index: Int, throwing error: UpdateCheckError) {
        continuations.remove(at: index).resume(throwing: error)
    }
}
