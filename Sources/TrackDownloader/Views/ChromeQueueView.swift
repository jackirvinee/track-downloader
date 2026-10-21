import SwiftUI
import TrackDownloaderChromeCompanion
import TrackDownloaderCore

struct ChromeQueueView: View {
    @ObservedObject var store: ChromeQueueStore
    let actionsEnabled: Bool
    @State private var isClearConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let loadError = store.loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if store.entries.isEmpty {
                Text("Pasted links and tracks queued from Chrome will wait here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.entries) { entry in
                            ChromeQueueRow(
                                entry: entry,
                                activity: activity(for: entry.id),
                                actionsEnabled: actionsEnabled,
                                preparation: store.preparations[entry.id] ?? .checking,
                                requested: store.requestedDownloads.contains(entry.id),
                                checkAgain: { store.checkAgain(entry.id) },
                                download: { store.download(entry.id) }
                            )
                        }
                    }
                }
                .frame(minHeight: 90, maxHeight: .infinity)
            }

            controls
        }
        .alert("Clear browser queue?", isPresented: $isClearConfirmationPresented) {
            Button("Clear Queue", role: .destructive) { store.clearWaiting() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Waiting and failed items will be removed. An active download will continue.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Track Queue")
                .font(.caption.weight(.semibold))
            Text("\(store.entries.count)/\(ChromeCompanionQueue.maximumRequestCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if store.isBatchRunning {
                Text("Downloading all")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if store.isRunning {
                Button("Cancel", role: .cancel, action: store.cancel)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityHint("Stops the current download and keeps unfinished queue items.")
            } else {
                Button("Download All", systemImage: "arrow.down.circle", action: store.downloadAll)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.entries.isEmpty || !actionsEnabled)
                    .accessibilityHint("Checks and downloads queued tracks one at a time.")
            }
            Spacer(minLength: 4)
            Button("Clear Queue", role: .destructive) {
                isClearConfirmationPresented = true
            }
            .disabled(waitingEntryCount == 0)
            .accessibilityHint("Asks before removing waiting and failed queue items.")
        }
        .controlSize(.small)
    }

    private var waitingEntryCount: Int {
        store.entries.filter { $0.id != store.activeRequestID }.count
    }

    private func activity(for requestID: UUID) -> ChromeQueueActivity {
        store.activeRequestID == requestID ? store.activity : .idle
    }
}

private struct ChromeQueueRow: View {
    let entry: ChromeCompanionQueueEntry
    let activity: ChromeQueueActivity
    let actionsEnabled: Bool
    let preparation: SourcePreflightState
    let requested: Bool
    let checkAgain: () -> Void
    let download: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .help(title)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusIsFailure ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .help(statusDetails)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if case .idle = activity, !requested {
                switch preparation {
                case .ready:
                    Button("Download", action: download)
                        .disabled(!actionsEnabled)
                case .unavailable, .invalidLink:
                    Button("Check again", action: checkAgain)
                case .idle, .checking:
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .controlSize(.mini)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var statusText: String {
        switch activity {
        case .checking: return "Checking source…"
        case .downloading(let progress):
            let percent = progress.fractionCompleted.map {
                " · " + $0.formatted(.percent.precision(.fractionLength(0)))
            } ?? ""
            return DownloadProgressView.title(for: progress.stage) + percent
        case .idle:
            if requested { return "Waiting to download" }
            if case .failed(let message) = entry.status { return message }
            switch preparation {
            case .idle, .checking: return "Checking source…"
            case .unavailable: return "Couldn’t check source"
            case .invalidLink(let message): return message
            case .ready(let result):
                let presentation = SourcePreflightPresentation(result: result)
                let facts = presentation.facts.filter { ["duration", "bitrate"].contains($0.id) }
                return ([subtitle] + facts.map { $0.id == "bitrate" ? "\($0.value) est." : $0.value }).joined(separator: " · ")
            }
        }
    }

    private var statusDetails: String {
        if case .ready(let result) = preparation {
            let presentation = SourcePreflightPresentation(result: result)
            let facts = presentation.facts.map { "\($0.label): \($0.value)" }
            return ([statusText] + facts + [presentation.assessment]).joined(separator: "\n")
        }
        return statusText
    }

    private var statusIsFailure: Bool {
        if case .failed = entry.status { return true }
        if case .unavailable = preparation { return true }
        if case .invalidLink = preparation { return true }
        return false
    }

    private var title: String {
        if case .ready(let result) = preparation {
            let presentation = SourcePreflightPresentation(result: result)
            if let uploader = presentation.facts.first(where: { $0.id == "uploader" })?.value {
                return "\(uploader) · \(presentation.title)"
            }
            return presentation.title
        }
        let trackTitle = entry.request.metadata?.title
            ?? entry.request.url.lastPathComponent.removingPercentEncoding
            ?? "Queued track"
        if let creator = entry.request.metadata?.creator {
            return "\(creator) · \(trackTitle)"
        }
        return trackTitle
    }

    private var subtitle: String {
        let platform = switch entry.request.metadata?.platform {
        case .youtube: "YouTube"
        case .soundcloud: "SoundCloud"
        case nil: entry.request.url.host?.contains("soundcloud") == true ? "SoundCloud" : "YouTube"
        }
        return platform
    }
}
