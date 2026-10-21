import SwiftUI

struct SourcePaneView<Content: View, QueueContent: View>: View {
    let status: SourcePaneStatusPresentation
    let outputDirectory: URL
    let history: [SourceHistoryItem]
    let openSettings: () -> Void
    let content: Content
    let queueContent: QueueContent
    init(status: SourcePaneStatusPresentation, outputDirectory: URL, history: [SourceHistoryItem], openSettings: @escaping () -> Void, @ViewBuilder content: () -> Content, @ViewBuilder queueContent: () -> QueueContent) {
        self.status = status; self.outputDirectory = outputDirectory; self.history = history; self.openSettings = openSettings; self.content = content(); self.queueContent = queueContent()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Source").font(.headline)
                    Label(status.text, systemImage: status.systemImage).font(.caption).foregroundStyle(statusForeground).accessibilityLabel(status.accessibilityLabel)
                }
                Spacer(minLength: 8)
                Button(action: openSettings) { Label("Settings", systemImage: "gearshape") }
                    .labelStyle(.iconOnly).keyboardShortcut(",", modifiers: .command).accessibilityLabel("Settings")
                    .accessibilityHint("Opens Track Downloader Settings.")
            }
            .padding(12)
            Divider()
            content.frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            Divider()
            queueContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(history) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.caption).lineLimit(1)
                        Text(item.savedText).font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if history.isEmpty { Text("No saved source history yet.").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text("Output").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(outputDirectory.path).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            // Keeps the sections top-aligned and lets the pane background cover
            // the full height ContentView hands it.
            Spacer(minLength: 0)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private var statusForeground: Color { switch status.role { case .failure: .red; case .warning: .orange; case .success: .green; case .neutral: .secondary; case .inProgress: .primary } }
}
