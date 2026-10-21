import AppKit
import Foundation
import ImageIO
import SwiftUI
import TrackDownloaderCore

struct LibraryToolbarMetrics {
    static let minimumPaneWidth: CGFloat = 520

    let horizontalPadding: CGFloat = 12
    let itemSpacing: CGFloat = 8
    let scopeWidth: CGFloat = 132
    let sortWidth: CGFloat = 132
    let iconButtonWidth: CGFloat = 28
    let minimumSearchWidth: CGFloat = 120

    func searchWidth(in paneWidth: CGFloat) -> CGFloat {
        let fixedWidth = (horizontalPadding * 2)
            + scopeWidth
            + sortWidth
            + (iconButtonWidth * 2)
            + (itemSpacing * 4)
        return max(minimumSearchWidth, paneWidth - fixedWidth)
    }
}

enum LibraryContentPresentation: Equatable {
    case unavailable(title: String, detail: String), noMatches(title: String, detail: String), empty(title: String, detail: String), populated
    static func resolve(isOutputDirectoryAvailable: Bool, visibleTrackCount: Int, hasSearchQuery: Bool, destinationTitle: String) -> Self {
        if !isOutputDirectoryAvailable { return .unavailable(title: "Output folder unavailable", detail: "Refresh the library or open the output folder in Finder.") }
        if visibleTrackCount > 0 { return .populated }
        return hasSearchQuery ? .noMatches(title: "No matching tracks", detail: "Clear the search or choose another scope.") : .empty(title: "\(destinationTitle) is empty", detail: "Choose another scope or add a selected track to this crate.")
    }
}

enum CatalogueCellPresentation {
    static func text(for track: DownloadedTrack, column: CatalogueColumn) -> String {
        switch column {
        case .artwork, .waveform: return ""
        case .track: return track.title
        case .artist: return track.artist?.trimmedNonEmpty ?? "—"
        case .format: return track.format
        case .quality, .duration, .codec, .bitrate, .sampleRate: return "—"
        case .added: return track.savedAt.formatted(date: .abbreviated, time: .omitted)
        case .album: return track.album?.trimmedNonEmpty ?? "—"
        case .genre: return track.genre?.trimmedNonEmpty ?? "—"
        case .source: return track.relativeDirectory?.trimmedNonEmpty ?? "—"
        case .fileSize: return track.fileSizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        }
    }
    static func accessibilityText(for track: DownloadedTrack, column: CatalogueColumn) -> String { "\(column.title): \(text(for: track, column: column))" }
}

struct CatalogueArtworkThumbnail: View {
    let fileURL: URL
    let artworkLoader: any EmbeddedArtworkLoading
    @State private var artworkData: Data?

    var body: some View {
        Group {
            if let artworkImage {
                Image(artworkImage, scale: 1, label: Text("Artwork available"))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipped()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Artwork unavailable")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: fileURL) {
            artworkData = nil
            let loadedArtwork = await artworkLoader.loadArtwork(from: fileURL)
            guard !Task.isCancelled,
                  let loadedArtwork,
                  Self.decodeArtwork(loadedArtwork) != nil else {
                return
            }
            artworkData = loadedArtwork
        }
    }

    private var artworkImage: CGImage? {
        artworkData.flatMap(Self.decodeArtwork)
    }

    private static func decodeArtwork(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

struct CatalogueWaveformThumbnail: View {
    let fileURL: URL
    let waveformLoader: any AudioWaveformLoading

    var body: some View {
        TrackWaveformView(fileURL: fileURL, waveformLoader: waveformLoader)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TrackWaveformView: View {
    let fileURL: URL
    let waveformLoader: any AudioWaveformLoading
    @State private var projection = WaveformProjection.unavailable

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)

            if projection.isUnavailable {
                Text("Waveform unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Canvas { context, size in
                    drawWaveform(in: &context, size: size)
                }
                .padding(.vertical, 3)
            }
        }
        .overlay {
            Rectangle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(projection.accessibilityLabel)
        .task(id: fileURL) {
            projection = .unavailable
            let loadedProjection = await waveformLoader.loadWaveform(from: fileURL)
            guard !Task.isCancelled else { return }
            projection = loadedProjection
        }
    }

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let maximumCount = max(Int(size.width), 1)
        let samples = projection.renderSamples(maximumCount: maximumCount)
        guard !samples.isEmpty else { return }

        let centerY = size.height / 2
        var centerLine = Path()
        centerLine.move(to: CGPoint(x: 0, y: centerY))
        centerLine.addLine(to: CGPoint(x: size.width, y: centerY))
        context.stroke(centerLine, with: .color(.primary.opacity(0.14)), lineWidth: 1)

        let columnWidth = size.width / CGFloat(samples.count)
        let lineWidth = max(1, columnWidth + 0.35)
        let lowColor = Color(.sRGB, red: 0.03, green: 0.38, blue: 0.95, opacity: 1)
        let midColor = Color(.sRGB, red: 0.96, green: 0.48, blue: 0.03, opacity: 1)
        let highColor = Color(.sRGB, red: 0.97, green: 0.94, blue: 0.86, opacity: 1)

        for (index, sample) in samples.enumerated() {
            let x = columnWidth * (CGFloat(index) + 0.5)
            strokeEnvelope(
                sample.lowAmplitude,
                color: lowColor,
                in: &context,
                x: x,
                centerY: centerY,
                size: size,
                lineWidth: lineWidth
            )
            strokeEnvelope(
                sample.midAmplitude,
                color: midColor,
                in: &context,
                x: x,
                centerY: centerY,
                size: size,
                lineWidth: lineWidth
            )
            strokeEnvelope(
                sample.highAmplitude,
                color: highColor,
                in: &context,
                x: x,
                centerY: centerY,
                size: size,
                lineWidth: lineWidth
            )
        }
    }

    private func strokeEnvelope(
        _ amplitude: Double,
        color: Color,
        in context: inout GraphicsContext,
        x: CGFloat,
        centerY: CGFloat,
        size: CGSize,
        lineWidth: CGFloat
    ) {
        guard amplitude > 0 else { return }
        let height = max(1, size.height * CGFloat(amplitude) * 0.94)
        stroke(
            in: &context,
            x: x,
            lowerY: centerY - height / 2,
            upperY: centerY + height / 2,
            lineWidth: lineWidth,
            color: color
        )
    }

    private func stroke(
        in context: inout GraphicsContext,
        x: CGFloat,
        lowerY: CGFloat,
        upperY: CGFloat,
        lineWidth: CGFloat,
        color: Color
    ) {
        var path = Path()
        path.move(to: CGPoint(x: x, y: lowerY))
        path.addLine(to: CGPoint(x: x, y: upperY))
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
        )
    }
}

private extension String { var trimmedNonEmpty: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value } }
