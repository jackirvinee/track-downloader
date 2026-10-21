import AppKit
import TrackDownloaderCore
import Foundation

protocol DownloadServicing: Sendable {
    var outputDirectory: URL { get }

    func download(
        sourceURL: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult
    func cancel()
}

@MainActor
final class DownloadStore: ObservableObject {
    @Published var link = ""
    @Published private(set) var state: DownloadState = .idle
    @Published private(set) var failure: DownloadFailurePresentation?

    let outputDirectory: URL
    private let service: any DownloadServicing
    private var activeRequestID: UUID?
    private var activeTask: Task<Void, Never>?
    private var lastSourceURL: URL?

    init(service: any DownloadServicing = DownloaderService()) {
        self.service = service
        self.outputDirectory = service.outputDirectory
    }

    #if DEBUG
    init(fixtureState: DownloadState, outputDirectory: URL) {
        self.service = FixtureDownloadService(outputDirectory: outputDirectory)
        self.outputDirectory = outputDirectory
        self.state = fixtureState
        if case .failed(let fixtureFailure) = fixtureState {
            self.failure = fixtureFailure
        }
    }
    #endif

    func download() {
        guard activeTask == nil else { return }

        let sourceURL: URL
        do {
            sourceURL = try URLValidator.normalize(link)
        } catch {
            failure = nil
            state = .invalidInput(error.localizedDescription)
            return
        }

        startDownload(sourceURL)
    }

    func retry() {
        guard activeTask == nil, failure != nil, let lastSourceURL else { return }
        startDownload(lastSourceURL)
    }

    func cancel() {
        guard activeTask != nil else { return }
        activeTask?.cancel()
        service.cancel()
        activeTask = nil
        activeRequestID = nil
        state = .cancelled
    }

    func reset() {
        cancel()
        link = ""
        failure = nil
        lastSourceURL = nil
        state = .idle
    }

    private func startDownload(_ sourceURL: URL) {
        let requestID = UUID()
        activeRequestID = requestID
        lastSourceURL = sourceURL
        failure = nil
        state = .running(DownloadProgress(stage: .validating, fractionCompleted: nil, detail: nil))
        let service = self.service
        let progressRelay = ProgressRelay { [weak self] progress in
            self?.receive(progress, for: requestID)
        }
        activeTask = Task { [weak self, service] in
            do {
                let result = try await service.download(sourceURL: sourceURL, onProgress: { progress in
                    progressRelay.send(progress)
                })
                guard !Task.isCancelled else { return }
                self?.finish(result, for: requestID)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish(error, for: requestID)
            }
        }
    }

    private func receive(_ progress: DownloadProgress, for requestID: UUID) {
        guard activeRequestID == requestID else { return }
        state = .running(progress)
    }

    private func finish(_ result: DownloadResult, for requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeTask = nil
        activeRequestID = nil
        state = .finished(result)
        link = ""
    }

    private func finish(_ error: Error, for requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeTask = nil
        activeRequestID = nil
        let typedFailure = (error as? DownloadFailurePresentation)
            ?? DownloadFailurePresentation(
                kind: .unexpected,
                title: "Download failed",
                message: error.localizedDescription,
                technicalDetails: nil
            )
        failure = typedFailure
        state = .failed(typedFailure)
    }

    func showOutputFolder() {
        NSWorkspace.shared.open(outputDirectory)
    }

    func showLog() {
        let logURL = outputDirectory.appendingPathComponent("track-downloader-last-download.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            showOutputFolder()
        }
    }

    func reveal(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func findBetterSource(for fileURL: URL) {
        let terms = SearchLinkBuilder.terms(from: fileURL)
        SearchLinkBuilder.urls(for: terms).forEach { NSWorkspace.shared.open($0) }
    }
}

private final class ProgressRelay: @unchecked Sendable {
    private let update: @MainActor @Sendable (DownloadProgress) -> Void

    init(_ update: @escaping @MainActor @Sendable (DownloadProgress) -> Void) {
        self.update = update
    }

    func send(_ progress: DownloadProgress) {
        let update = update
        Task { @MainActor in
            update(progress)
        }
    }
}
