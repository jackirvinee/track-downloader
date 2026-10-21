import TrackDownloaderCore
import SwiftUI

struct DownloadProgressView: View {
    let progress: DownloadProgress
    let sourceTitle: String?
    let cancel: () -> Void

    init(
        progress: DownloadProgress,
        sourceTitle: String? = nil,
        cancel: @escaping () -> Void
    ) {
        self.progress = progress
        self.sourceTitle = sourceTitle
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(sourceTitle ?? "Current transfer")
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let normalizedFraction {
                    Text(normalizedFraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .accessibilityHidden(true)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Button("Cancel", action: cancel)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityHint("Cancels this download without changing any existing files.")
            }

            VUProgressMeter(
                fractionCompleted: normalizedFraction,
                stageLabel: title
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Download in progress. \(title). \(detail)")
    }

    static func title(for stage: DownloadStage) -> String {
        switch stage {
        case .validating: "Checking link"
        case .resolving: "Finding the best source"
        case .downloading: "Downloading audio"
        case .processing: "Adding artwork and metadata"
        case .measuringQuality: "Measuring saved audio"
        }
    }

    private var title: String {
        Self.title(for: progress.stage)
    }

    private var normalizedFraction: Double? {
        progress.fractionCompleted.map(VUProgressMeterRules.normalizedFraction)
    }

    private var detail: String {
        if let detail = progress.detail, !detail.isEmpty { return detail }
        return switch progress.stage {
        case .validating: "Making sure this is a supported link."
        case .resolving: "Reading available source formats."
        case .downloading: "Saving the selected audio stream."
        case .processing: "Preserving tags and cover artwork where available."
        case .measuringQuality: "Checking codec, bitrate, and sample rate."
        }
    }

}
