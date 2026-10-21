import Combine

@MainActor
final class EngineHealthStore: ObservableObject {
    @Published private(set) var state: EngineHealthState = .idle

    private let checker: any EngineHealthChecking
    private var firstOpenRefreshHasStarted = false
    private var nextRequestID: UInt64 = 0
    private var activeRequestID: UInt64?
    private var activeTask: Task<Void, Never>?

    init(checker: any EngineHealthChecking = EngineHealthService()) {
        self.checker = checker
    }

    func refreshIfNeeded() {
        guard !firstOpenRefreshHasStarted else { return }
        firstOpenRefreshHasStarted = true
        startRefresh()
    }

    func refresh() {
        startRefresh()
    }

    private func startRefresh() {
        activeTask?.cancel()
        nextRequestID &+= 1
        let requestID = nextRequestID
        activeRequestID = requestID
        state = .checking
        let checker = self.checker

        activeTask = Task { [weak self, checker] in
            let snapshot = await checker.check()
            self?.finish(snapshot, for: requestID)
        }
    }

    private func finish(_ snapshot: EngineHealthSnapshot, for requestID: UInt64) {
        guard activeRequestID == requestID else { return }
        activeTask = nil
        activeRequestID = nil
        state = .ready(snapshot)
    }
}
