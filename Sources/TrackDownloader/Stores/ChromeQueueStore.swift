import Combine
import Foundation
import TrackDownloaderChromeCompanion
import TrackDownloaderCore

enum ChromeQueueActivity: Equatable {
    case idle
    case checking
    case downloading(DownloadProgress)
}

@MainActor
final class ChromeQueueStore: ObservableObject {
    @Published private(set) var entries: [ChromeCompanionQueueEntry] = []
    @Published private(set) var activeRequestID: UUID?
    @Published private(set) var activity: ChromeQueueActivity = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var isBatchRunning = false
    @Published private(set) var lastCompletedResult: DownloadResult?
    @Published private(set) var loadError: String?

    @Published private(set) var preparations: [UUID: SourcePreflightState] = [:]
    @Published private(set) var requestedDownloads: [UUID] = []
    @Published private(set) var inputMessage: String?
    private var preparationEnabled = false
    private var preparationTask: Task<Void, Never>?
    private let preparationService: any SourcePreflightServicing

    private let queue: ChromeCompanionQueue
    private let preflightService: any SourcePreflightServicing
    private let downloadService: any DownloadServicing
    private var activeTask: Task<Void, Never>?
    private var sessionID: UUID?

    init(
        queue: ChromeCompanionQueue = ChromeCompanionQueue(),
        preflightService: any SourcePreflightServicing = SourcePreflightService(),
        downloadService: any DownloadServicing = DownloaderService(),
        preparationService: any SourcePreflightServicing = SourcePreflightService()
    ) {
        self.preparationService = preparationService
        self.queue = queue
        self.preflightService = preflightService
        self.downloadService = downloadService
        reload()
    }

    func reload() {
        do {
            entries = try queue.entries()
            loadError = nil
            prepareWaiting()
        } catch {
            loadError = "The browser queue could not be read."
        }
    }

    func enablePreparation() {
        preparationEnabled = true
        prepareWaiting()
    }

    @discardableResult
    func enqueueLink(_ value: String) -> Bool {
        do {
            let url = try URLValidator.normalize(value)
            let request = ChromeCompanionRequest(requestID: UUID(), url: url,
                issuedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
            let outcome = try queue.enqueue(request)
            inputMessage = outcome == .duplicate ? "That link is already queued." : nil
            reload()
            return true
        } catch {
            inputMessage = (error as? ChromeCompanionQueueError) == .capacityReached
                ? "Queue full. Download queued tracks before adding more."
                : "Paste a supported YouTube or SoundCloud link."
            return false
        }
    }

    func checkAgain(_ id: UUID) {
        preparations[id] = nil
        prepareWaiting()
    }

    private func prepareWaiting() {
        guard preparationEnabled, preparationTask == nil else { return }
        preparationTask = Task { [weak self] in
            guard let self else { return }
            while let entry = self.entries.first(where: { self.preparations[$0.id] == nil }) {
                self.preparations[entry.id] = .checking
                do {
                    let result = try await self.preparationService.inspect(sourceURL: entry.request.url)
                    self.preparations[entry.id] = .ready(result)
                } catch {
                    self.preparations[entry.id] = .unavailable(self.preflightMessage(for: error))
                }
            }
            self.preparationTask = nil
        }
    }

    func download(_ requestID: UUID) {
        guard entries.contains(where: { $0.id == requestID }) else { return }
        start(requestIDs: [requestID], isBatch: false)
    }

    func downloadAll() {
        start(requestIDs: entries.map(\.id), isBatch: true)
    }

    func cancel() {
        guard isRunning else { return }
        sessionID = nil
        isRunning = false
        activeTask?.cancel()
        activeTask = nil
        requestedDownloads = []
        preflightService.cancel()
        downloadService.cancel()
        activeRequestID = nil
        activity = .idle
        isBatchRunning = false
        reload()
    }

    func clearWaiting() {
        do {
            try queue.clearWaiting(excluding: activeRequestID)
            reload()
        } catch {
            loadError = "The browser queue could not be updated."
        }
    }

    private func start(requestIDs: [UUID], isBatch: Bool) {
        guard !requestIDs.isEmpty else { return }
        for id in requestIDs where id != activeRequestID && !requestedDownloads.contains(id) {
            requestedDownloads.append(id)
        }
        guard !isRunning else { return }
        let sessionID = UUID()
        self.sessionID = sessionID
        isRunning = true
        isBatchRunning = isBatch
        activeTask = Task { [weak self] in
            guard let self else { return }
            while !self.requestedDownloads.isEmpty {
                let requestID = self.requestedDownloads.removeFirst()
                guard !Task.isCancelled, self.sessionID == sessionID else { break }
                guard let entry = self.entries.first(where: { $0.id == requestID }) else { continue }
                await self.process(entry, sessionID: sessionID)
            }
            self.finishSession(sessionID)
        }
    }

    private func process(_ entry: ChromeCompanionQueueEntry, sessionID: UUID) async {
        activeRequestID = entry.id
        activity = .checking
        do {
            try queue.markQueued(requestID: entry.id)
            reload()
            if case .ready = preparations[entry.id] {} else {
                _ = try await preflightService.inspect(sourceURL: entry.request.url)
            }
        } catch {
            guard !Task.isCancelled, self.sessionID == sessionID else { return }
            markFailed(entry.id, message: preflightMessage(for: error))
            return
        }

        guard !Task.isCancelled, self.sessionID == sessionID else { return }
        activity = .downloading(
            DownloadProgress(stage: .validating, fractionCompleted: nil, detail: nil)
        )
        let progressRelay = ChromeQueueProgressRelay { [weak self] progress in
            guard let self,
                  self.sessionID == sessionID,
                  self.activeRequestID == entry.id else { return }
            self.activity = .downloading(progress)
        }

        do {
            let progressHandler: @Sendable (DownloadProgress) -> Void = { progress in
                progressRelay.send(progress)
            }
            let result = try await downloadService.download(
                sourceURL: entry.request.url,
                onProgress: progressHandler
            )
            guard !Task.isCancelled, self.sessionID == sessionID else { return }
            try queue.remove(requestID: entry.id)
            lastCompletedResult = result
            reload()
        } catch {
            guard !Task.isCancelled, self.sessionID == sessionID else { return }
            markFailed(entry.id, message: downloadMessage(for: error))
        }
    }

    private func markFailed(_ requestID: UUID, message: String) {
        do {
            try queue.markFailed(requestID: requestID, message: message)
            reload()
        } catch {
            loadError = "The browser queue could not save this failure."
        }
    }

    private func finishSession(_ sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        self.sessionID = nil
        isRunning = false
        activeTask = nil
        activeRequestID = nil
        activity = .idle
        isBatchRunning = false
        reload()
    }

    private func preflightMessage(for error: Error) -> String {
        (error as? SourcePreflightServiceError)?.message
            ?? "This source could not be checked right now."
    }

    private func downloadMessage(for error: Error) -> String {
        (error as? DownloadFailurePresentation)?.message
            ?? "This source could not be downloaded."
    }
}

private final class ChromeQueueProgressRelay: @unchecked Sendable {
    private let update: @MainActor @Sendable (DownloadProgress) -> Void

    init(_ update: @escaping @MainActor @Sendable (DownloadProgress) -> Void) {
        self.update = update
    }

    func send(_ progress: DownloadProgress) {
        let update = update
        Task { @MainActor in update(progress) }
    }
}
