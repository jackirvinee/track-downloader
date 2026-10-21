import Foundation
import XCTest
@testable import TrackDownloader

@MainActor
final class EngineHealthStoreTests: XCTestCase {
    func testRefreshIfNeededStartsOnlyTheFirstSettingsCheckThenManualRefreshStartsAnother() async {
        let checker = ControlledEngineHealthChecker()
        let store = EngineHealthStore(checker: checker)

        store.refreshIfNeeded()
        XCTAssertEqual(store.state, .checking)
        store.refreshIfNeeded()

        await eventually { await checker.invocationCount == 1 }
        let first = snapshot(version: "2026.08.14")
        await checker.resume(at: 0, with: first)
        await eventually { store.state == .ready(first) }

        store.refresh()
        XCTAssertEqual(store.state, .checking)
        await eventually { await checker.invocationCount == 2 }
        let second = snapshot(version: "2026.08.15")
        await checker.resume(at: 0, with: second)
        await eventually { store.state == .ready(second) }
    }

    func testLateFirstOpenResultCannotOverwriteNewerManualRefresh() async {
        let checker = ControlledEngineHealthChecker()
        let store = EngineHealthStore(checker: checker)

        store.refreshIfNeeded()
        await eventually { await checker.invocationCount == 1 }
        store.refresh()
        await eventually { await checker.invocationCount == 2 }

        let manualSnapshot = snapshot(version: "2026.08.15")
        await checker.resume(at: 1, with: manualSnapshot)
        await eventually { store.state == .ready(manualSnapshot) }

        await checker.resume(at: 0, with: snapshot(version: "2026.01.01"))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(store.state, .ready(manualSnapshot))
    }

    private func snapshot(version: String) -> EngineHealthSnapshot {
        EngineHealthSnapshot(
            tools: [
                EngineToolHealth(id: .ytDLP, status: .available(version: version), recoveryCommand: nil)
            ],
            ejsEnabled: true
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

private actor ControlledEngineHealthChecker: EngineHealthChecking {
    private var continuations: [CheckedContinuation<EngineHealthSnapshot, Never>] = []
    private(set) var invocationCount = 0

    func check() async -> EngineHealthSnapshot {
        invocationCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(at index: Int, with snapshot: EngineHealthSnapshot) {
        continuations.remove(at: index).resume(returning: snapshot)
    }
}
