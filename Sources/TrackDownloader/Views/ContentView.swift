import AppKit
import SwiftUI
import TrackDownloaderCore
import TrackDownloaderChromeCompanion

@MainActor
struct ContentView: View {
    @StateObject private var store: DownloadStore
    @StateObject private var preflightStore: SourcePreflightStore
    @StateObject private var downloadedTrackStore: DownloadedTrackStore
    @StateObject private var chromeQueueStore: ChromeQueueStore
    @State private var queuedLink = ""
    @State private var selectedTrackURL: URL?
    @State private var resultReentryTask: Task<Void, Never>?
    @FocusState private var linkFieldFocused: Bool
    private let failureDetailsInitiallyExpanded: Bool
    private let linkFieldInitiallyFocused: Bool
    private let presentSettings: () -> Void

    init(
        store: DownloadStore? = nil,
        preflightStore: SourcePreflightStore? = nil,
        downloadedTrackStore: DownloadedTrackStore? = nil,
        chromeQueueStore: ChromeQueueStore? = nil,
        failureDetailsInitiallyExpanded: Bool = false,
        linkFieldInitiallyFocused: Bool = false,
        presentSettings: @escaping () -> Void
    ) {
        let resolvedStore = store ?? DownloadStore()
        _store = StateObject(wrappedValue: resolvedStore)
        _preflightStore = StateObject(wrappedValue: preflightStore ?? SourcePreflightStore())
        #if DEBUG
        let resolvedDownloadedTrackStore = downloadedTrackStore
            ?? TrackDownloaderFixture.downloadedTracksStore(outputDirectory: resolvedStore.outputDirectory)
            ?? DownloadedTrackStore(outputDirectory: resolvedStore.outputDirectory)
        #else
        let resolvedDownloadedTrackStore = downloadedTrackStore
            ?? DownloadedTrackStore(outputDirectory: resolvedStore.outputDirectory)
        #endif
        _downloadedTrackStore = StateObject(
            wrappedValue: resolvedDownloadedTrackStore
        )
        _chromeQueueStore = StateObject(wrappedValue: chromeQueueStore ?? ChromeQueueStore())
        self.failureDetailsInitiallyExpanded = failureDetailsInitiallyExpanded
        self.linkFieldInitiallyFocused = linkFieldInitiallyFocused
        self.presentSettings = presentSettings
    }

    var body: some View {
        // HSplitView sizes itself from each pane's *ideal* height (it asks the
        // per-pane NSHostingView for its intrinsicContentSize) and ignores the
        // height it is proposed. Flexible frames on or inside the panes cannot
        // change that. So this view — the only one that knows the window-height
        // budget — measures the space once and hands each pane a definite height.
        GeometryReader { proxy in
            HSplitView {
                SourcePaneView(
                    status: sourceStatus,
                    outputDirectory: store.outputDirectory,
                    history: sourceHistory,
                    openSettings: openSettings
                ) {
                    queueInput
                } queueContent: {
                    ChromeQueueView(
                        store: chromeQueueStore,
                        actionsEnabled: !manualDownloadIsRunning
                    )
                }
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                .frame(height: proxy.size.height)

                DownloadedTracksView(store: downloadedTrackStore, selection: $selectedTrackURL)
                    .frame(minWidth: LibraryToolbarMetrics.minimumPaneWidth, idealWidth: 660)
                    .frame(height: proxy.size.height)
            }
        }
        // The status bar sits outside the vertical flow, so it stays anchored to
        // the bottom edge and the panes above it inherit the remaining height.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                WorkspaceStatusBar(presentation: workspaceStatus)
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .onAppear {
            if case .finished(let result) = store.state {
                handleFinishedState(result)
            } else {
                downloadedTrackStore.refresh()
            }
            if linkFieldInitiallyFocused {
                linkFieldFocused = true
            } else if case .idle = store.state {
                linkFieldFocused = true
            }
            chromeQueueStore.enablePreparation()
            chromeQueueStore.reload()
        }
        .onChange(of: store.state) { newState in
            switch newState {
            case .idle, .invalidInput, .cancelled:
                cancelResultReentry()
                restoreLinkFocus()
            case .finished(let result):
                handleFinishedState(result)
            case .running, .failed:
                cancelResultReentry()
            }
        }
        .onChange(of: store.link) { newLink in
            preflightStore.sourceChanged(newLink)
        }
        .onChange(of: chromeQueueStore.lastCompletedResult) { result in
            guard let result else { return }
            downloadedTrackStore.refresh(selecting: result.fileURL) {
                selectedTrackURL = $0
            }
        }
        .task {
            preflightStore.sourceChanged(store.link)
        }
        .onDisappear {
            cancelResultReentry()
        }
    }

    private var sourceStatus: SourcePaneStatusPresentation {
        SourcePaneStatusPresentation(downloadState: store.state, preflightState: preflightStore.state)
    }

    private var sourceHistory: [SourceHistoryItem] {
        SourceHistoryItem.recent(from: downloadedTrackStore.tracks)
    }

    private var workspaceStatus: WorkspaceStatusPresentation {
        WorkspaceStatusPresentation(
            sourceStatus: sourceStatus,
            outputDirectory: store.outputDirectory,
            libraryCount: downloadedTrackStore.tracks.count
        )
    }

    @ViewBuilder
    private var mainRegion: some View {
        switch store.state {
        case .idle, .invalidInput, .cancelled:
            sourceForm
        case .running(let progress):
            DownloadProgressView(
                progress: progress,
                sourceTitle: activeSourceTitle,
                cancel: store.cancel
            )
        case .finished(let result):
            QualityResultView(
                result: result,
                reveal: { store.reveal(result.fileURL) },
                findBetterSource: { store.findBetterSource(for: result.fileURL) },
                reset: startNewDownload
            )
        case .failed(let failure):
            DownloadFailureView(
                failure: failure,
                retry: store.retry,
                openCollection: store.showOutputFolder,
                showLog: store.showLog,
                reset: startNewDownload,
                detailsInitiallyExpanded: failureDetailsInitiallyExpanded
            )
        }
    }

    private var queueInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            DownloadFormView(link: Binding(
                get: { queuedLink },
                set: { value in
                    let previous = queuedLink
                    queuedLink = value
                    // Multi-character insertion/replacement is paste. Typing submits with Return.
                    if value.count - previous.count > 1 || (!value.hasPrefix(previous) && value.count > 1) {
                        submitQueuedLink()
                    }
                }), focused: $linkFieldFocused)
                .onSubmit(submitQueuedLink)
            if let message = chromeQueueStore.inputMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func submitQueuedLink() {
        guard !queuedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if chromeQueueStore.enqueueLink(queuedLink) {
            queuedLink = ""
            linkFieldFocused = true
        }
    }

    private var sourceForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            DownloadFormView(link: $store.link, focused: $linkFieldFocused)
            SourcePreflightCard(
                state: preflightStore.state,
                download: startPreparedDownload,
                checkAgain: preflightStore.checkAgain,
                downloadEnabled: !chromeQueueStore.isRunning
            )
        }
    }

    private var activeSourceTitle: String? {
        guard case .ready(let result) = preflightStore.state else { return nil }
        let title = SourcePreflightPresentation(result: result).title
        return title == "Source available" ? nil : title
    }

    private func startPreparedDownload() {
        guard case .ready = preflightStore.state, !chromeQueueStore.isRunning else { return }
        preflightStore.prepareForDownload()
        store.download()
    }

    private var manualDownloadIsRunning: Bool {
        if case .running = store.state { return true }
        return false
    }


    private func startNewDownload() {
        store.reset()
        restoreLinkFocus()
    }

    private func handleFinishedState(_ result: DownloadResult) {
        downloadedTrackStore.refresh(selecting: result.fileURL) {
            selectedTrackURL = $0
        }
        scheduleResultReentry()
    }

    private func scheduleResultReentry() {
        cancelResultReentry()
        resultReentryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: SourceResultReentryPolicy.delayNanoseconds)
            guard !Task.isCancelled, SourceResultReentryPolicy.shouldSchedule(for: store.state) else { return }
            startNewDownload()
        }
    }

    private func cancelResultReentry() {
        resultReentryTask?.cancel()
        resultReentryTask = nil
    }

    private func restoreLinkFocus() {
        linkFieldFocused = false
        Task { @MainActor in
            await Task.yield()
            linkFieldFocused = true
        }
    }

    private func openSettings() {
        presentSettings()
    }

}
