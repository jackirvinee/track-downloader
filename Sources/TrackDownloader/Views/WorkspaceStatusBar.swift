import SwiftUI

struct WorkspaceStatusBar: View {
    let presentation: WorkspaceStatusPresentation

    var body: some View {
        HStack(spacing: 12) {
            Label(presentation.stateText, systemImage: presentation.stateSystemImage)
                .foregroundStyle(statusColor)
            Divider().frame(height: 14)
            Text("Output").foregroundStyle(.secondary)
            Text(presentation.outputPath)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            Text(presentation.libraryText).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var statusColor: Color {
        switch presentation.stateRole {
        case .neutral: .secondary
        case .inProgress: .primary
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}
