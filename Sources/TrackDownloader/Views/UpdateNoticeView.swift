import SwiftUI

struct UpdateNoticePresentation: Equatable {
    let title: String
    let versionText: String
    let notes: String
    let downloadTitle: String
    let downloadURL: URL

    init(release: UpdateRelease) {
        title = "Update available"
        versionText = "Version \(release.version)"
        notes = release.notes
        downloadTitle = "Download from GitHub"
        downloadURL = release.pageURL
    }
}

struct UpdateNoticeView: View {
    let release: UpdateRelease
    let dismiss: () -> Void
    @Environment(\.openURL) private var openURL

    private var presentation: UpdateNoticePresentation {
        UpdateNoticePresentation(release: release)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.headline)
                Text(presentation.versionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(presentation.notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Button(presentation.downloadTitle) {
                    openURL(presentation.downloadURL)
                }
                .accessibilityHint("Opens this release on GitHub in your default browser.")
            }

            Spacer(minLength: 0)

            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss update notice")
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
