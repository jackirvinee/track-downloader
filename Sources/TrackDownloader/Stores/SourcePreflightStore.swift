import Combine
import Foundation
import TrackDownloaderCore

@MainActor
final class SourcePreflightStore: ObservableObject {
    @Published private(set) var state: SourcePreflightState = .idle

    private let service: any SourcePreflightServicing
    private let debounceNanoseconds: UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var generation: UInt64 = 0
    private var activeTask: Task<Void, Never>?
    private var normalizedURL: URL?
    private var lastReadyResult: SourcePreflightResult?

    init(
        service: any SourcePreflightServicing = SourcePreflightService(),
        debounceNanoseconds: UInt64 = 400_000_000,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.service = service
        self.debounceNanoseconds = debounceNanoseconds
        self.sleep = sleep
    }

    #if DEBUG
    init(fixtureState: SourcePreflightState) {
        self.service = SourcePreflightService()
        self.debounceNanoseconds = 0
        self.sleep = { _ in }
        self.state = fixtureState
        if case .ready(let result) = fixtureState {
            self.lastReadyResult = result
            self.normalizedURL = URL(string: "https://soundcloud.com/example/night-drive")
        }
    }
    #endif

    func sourceChanged(_ value: String) {
        let normalized: URL
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cancelActiveInspection()
            normalizedURL = nil
            state = .idle
            return
        }

        do {
            normalized = try URLValidator.normalize(value)
        } catch {
            cancelActiveInspection()
            normalizedURL = nil
            state = .invalidLink(error.localizedDescription)
            return
        }

        if normalized == normalizedURL,
           (matchesCheckingOrReadyState || activeTask != nil) {
            return
        }

        cancelActiveInspection()
        normalizedURL = normalized
        startInspection(of: normalized, afterDebounce: true)
    }

    func checkAgain() {
        guard let normalizedURL else { return }

        cancelActiveInspection()
        startInspection(of: normalizedURL, afterDebounce: false)
    }

    func prepareForDownload() {
        cancelActiveInspection()
        if let lastReadyResult {
            state = .ready(lastReadyResult)
        }
    }

    private var matchesCheckingOrReadyState: Bool {
        switch state {
        case .checking, .ready:
            true
        case .idle, .unavailable, .invalidLink:
            false
        }
    }

    private func cancelActiveInspection() {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        service.cancel()
    }

    private func startInspection(of sourceURL: URL, afterDebounce: Bool) {
        let requestGeneration = generation
        let service = service
        let sleep = sleep

        if !afterDebounce {
            state = .checking
        }

        activeTask = Task { [weak self, service, sleep] in
            if afterDebounce {
                do {
                    try await sleep(self?.debounceNanoseconds ?? 0)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  let self,
                  self.generation == requestGeneration else { return }

            self.state = .checking

            do {
                let result = try await service.inspect(sourceURL: sourceURL)
                guard !Task.isCancelled,
                      self.generation == requestGeneration else { return }
                self.activeTask = nil
                self.lastReadyResult = result
                self.state = .ready(result)
            } catch {
                guard !Task.isCancelled,
                      self.generation == requestGeneration else { return }
                self.activeTask = nil
                let message = (error as? SourcePreflightServiceError)?.message
                    ?? SourcePreflightServiceError.transient.message
                self.state = .unavailable(message)
            }
        }
    }
}
