import SwiftUI

struct DownloadFailureView: View {
    let failure: DownloadFailurePresentation
    let retry: () -> Void
    let openCollection: () -> Void
    let showLog: () -> Void
    let reset: () -> Void
    @State private var isDetailsExpanded: Bool

    init(
        failure: DownloadFailurePresentation,
        retry: @escaping () -> Void,
        openCollection: @escaping () -> Void,
        showLog: @escaping () -> Void,
        reset: @escaping () -> Void,
        detailsInitiallyExpanded: Bool = false
    ) {
        self.failure = failure
        self.retry = retry
        self.openCollection = openCollection
        self.showLog = showLog
        self.reset = reset
        _isDetailsExpanded = State(initialValue: detailsInitiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(failure.title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(isCollectionRecovery ? Color.primary : Color.red)

            Text(failure.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .missingDependency(_, let command) = failure.kind {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Install in Terminal")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }

            if let details = failure.technicalDetails, !details.isEmpty,
               !isInstallCommand(details) {
                DisclosureGroup("Technical details", isExpanded: $isDetailsExpanded) {
                    Text(details)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .font(.caption)
                .accessibilityLabel("Technical details: \(details)")
            }

            HStack(spacing: 8) {
                if isCollectionRecovery {
                    Button("Open Collection", action: openCollection)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("o", modifiers: .command)
                    .accessibilityHint("Opens the local output folder without selecting a file.")
                } else if isMissingDependency {
                    Button("Check Again", action: retry)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r", modifiers: .command)
                } else {
                    Button("Try Again", action: retry)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r", modifiers: .command)
                }

                if shouldShowLog {
                    Button("Open Log", action: showLog)
                        .buttonStyle(.bordered)
                }

                Spacer()

                Button("New Link", action: reset)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(failure.title). \(failure.message)")
    }

    private var isMissingDependency: Bool {
        if case .missingDependency = failure.kind { return true }
        return false
    }

    private var isCollectionRecovery: Bool {
        if case .alreadyInCollection = failure.kind { return true }
        return false
    }

    private var shouldShowLog: Bool {
        if isCollectionRecovery {
            return false
        }
        return switch failure.kind {
        case .extractor, .outputFileMissing, .qualityUnavailable, .unexpected:
            true
        case .unsupportedURL, .missingDependency, .alreadyInCollection, .cancelled:
            false
        }
    }

    private var symbol: String {
        if isCollectionRecovery {
            return "checkmark.circle"
        }
        return isMissingDependency ? "wrench.and.screwdriver.fill" : "exclamationmark.triangle.fill"
    }

    private func isInstallCommand(_ value: String) -> Bool {
        if case .missingDependency(_, let command) = failure.kind {
            return value == command
        }
        return false
    }
}
