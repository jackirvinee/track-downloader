import SwiftUI
import TrackDownloaderCore

struct LibrarySelectionDetailView: View {
    let track: DownloadedTrack
    let waveformLoader: any AudioWaveformLoading
    let showInFinder: (DownloadedTrack) -> Void
    let findBetterSource: (DownloadedTrack) -> Void

    private let displayedFields: [TrackInspectorField] = [
        .path,
        .format,
        .added,
        .fileSize,
        .album,
        .genre,
        .source,
    ]

    var body: some View {
        let presentation = TrackInspectorPresentation(track: track)

        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(presentation.title)
                        .font(.callout.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(presentation.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button("Show in Finder", systemImage: "folder") {
                    showInFinder(track)
                }
                Button("Find Better Source", systemImage: "magnifyingglass") {
                    findBetterSource(track)
                }
            }

            TrackWaveformView(
                fileURL: track.fileURL,
                waveformLoader: waveformLoader
            )
            .frame(height: 96)

            Divider()

            ForEach(displayedFields) { field in
                let value = presentation.value(for: field)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(field.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    Text(value)
                        .font(field.isTechnical ? .caption.monospaced() : .caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(field.label): \(value)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected track details for \(presentation.title)")
    }
}
