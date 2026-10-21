import TrackDownloaderCore
import ImageIO
import SwiftUI

struct QualityResultView: View {
    let result: DownloadResult
    let reveal: () -> Void
    let findBetterSource: () -> Void
    let reset: () -> Void
    private let artworkLoader: any EmbeddedArtworkLoading
    @State private var artworkData: Data?

    init(
        result: DownloadResult,
        reveal: @escaping () -> Void,
        findBetterSource: @escaping () -> Void,
        reset: @escaping () -> Void,
        artworkLoader: any EmbeddedArtworkLoading = EmbeddedArtworkLoader()
    ) {
        self.result = result
        self.reveal = reveal
        self.findBetterSource = findBetterSource
        self.reset = reset
        self.artworkLoader = artworkLoader
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            resultHeader

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Location", value: result.fileURL.path).font(.caption.monospaced()).textSelection(.enabled)
                Divider()
                LabeledContent("Codec", value: result.quality.codec.uppercased())
                LabeledContent("Bitrate", value: result.quality.bitrateLabel)
                LabeledContent("Sample rate", value: result.quality.sampleRateLabel ?? "—")
                Divider()
                verdict
            }
            .font(.caption)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    actionButtons
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 8) {
                    actionButtons
                }
            }
        }
        .accessibilityElement(children: .contain)
        .task(id: result.fileURL) {
            artworkData = nil
            artworkData = await artworkLoader.loadArtwork(from: result.fileURL)
        }
    }

    @ViewBuilder
    private var resultHeader: some View {
        if let artworkImage {
            HStack(alignment: .top, spacing: 10) {
                Image(artworkImage, scale: 1, label: Text("Embedded cover artwork"))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                resultText
            }
        } else {
            resultText
        }
    }

    private var resultText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(displayTitle, systemImage: "checkmark.circle.fill")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if let metadataLine {
                Text(metadataLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var artworkImage: CGImage? {
        guard let artworkData,
              let source = CGImageSourceCreateWithData(artworkData as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private var displayTitle: String {
        let title = result.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? result.fileURL.deletingPathExtension().lastPathComponent : title
    }

    private var verdict: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(result.quality.verdict.displayName, systemImage: verdictSymbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(verdictColor)
            Text(result.quality.verdict.resultSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityLabel("\(result.quality.verdict.displayName). \(result.quality.verdict.resultSummary)")
    }

    @ViewBuilder
    private var actionButtons: some View {
        if result.quality.verdict.shouldFindBetterSource {
            Button(action: findBetterSource) {
                Label("Find Better Source", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)

            Button(action: reveal) {
                Label("Show in Finder", systemImage: "folder")
            }
        } else {
            Button(action: reveal) {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
        }

        Button(action: reset) {
            Label("New Download", systemImage: "plus")
        }
        .keyboardShortcut("n", modifiers: .command)
    }

    private var facts: some View {
        ViewThatFits(in: .horizontal) {
            factsLine
            factsStack
        }
        .accessibilityLabel(qualityFactsAccessibilityLabel)
    }

    private var factsLine: some View {
        HStack(spacing: 6) {
            Text(result.quality.codec.uppercased())
            separator
            Text(result.quality.bitrateLabel)
            if let sampleRate = result.quality.sampleRateLabel {
                separator
                Text(sampleRate)
            }
        }
        .qualityFactsStyle()
    }

    private var factsStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.quality.codec.uppercased())
            HStack(spacing: 6) {
                Text(result.quality.bitrateLabel)
                if let sampleRate = result.quality.sampleRateLabel {
                    separator
                    Text(sampleRate)
                }
            }
        }
        .qualityFactsStyle()
    }

    private var separator: some View {
        Text("•")
            .foregroundStyle(.tertiary)
    }

    private var metadataLine: String? {
        [result.metadata.artist, result.metadata.album, result.metadata.genre]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " • ")
            .nilIfEmpty
    }

    private var qualityFactsAccessibilityLabel: String {
        let sampleRate = result.quality.sampleRateLabel.map { ", sample rate \($0)" } ?? ""
        return "Bitrate \(result.quality.bitrateLabel), codec \(result.quality.codec)\(sampleRate)"
    }

    private var verdictSymbol: String {
        switch result.quality.verdict {
        case .excellent:
            return "checkmark.seal.fill"
        case .good:
            return "checkmark.circle.fill"
        case .borderline:
            return "exclamationmark.circle.fill"
        case .low:
            return "exclamationmark.triangle.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var verdictColor: Color {
        switch result.quality.verdict {
        case .excellent, .good:
            return .green
        case .borderline:
            return .orange
        case .low:
            return .red
        case .unknown:
            return .secondary
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension View {
    func qualityFactsStyle() -> some View {
        font(.caption.monospaced())
            .foregroundStyle(.secondary)
    }
}
