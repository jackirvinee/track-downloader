import Foundation
import TrackDownloaderCore

enum SourceResultReentryPolicy {
    static let delayNanoseconds: UInt64 = 1_200_000_000

    static func shouldSchedule(for state: DownloadState) -> Bool {
        if case .finished = state { return true }
        return false
    }
}

enum SemanticStatusRole: Equatable { case neutral, inProgress, success, warning, failure }

struct SourcePaneStatusPresentation: Equatable {
    let text: String
    let systemImage: String
    let role: SemanticStatusRole
    let accessibilityLabel: String

    init(text: String, systemImage: String, role: SemanticStatusRole, accessibilityLabel: String) {
        self.text = text; self.systemImage = systemImage; self.role = role; self.accessibilityLabel = accessibilityLabel
    }

    init(downloadState: DownloadState, preflightState: SourcePreflightState) {
        let resolved: (String, String, SemanticStatusRole)
        switch downloadState {
        case .running: resolved = ("Download in progress", "arrow.down.circle", .inProgress)
        case .finished: resolved = ("Saved", "checkmark.circle", .success)
        case .failed: resolved = ("Download failed", "exclamationmark.triangle", .failure)
        case .cancelled: resolved = ("Ready", "checkmark.circle", .neutral)
        case .idle, .invalidInput:
            switch preflightState {
            case .idle: resolved = ("Ready", "checkmark.circle", .neutral)
            case .checking: resolved = ("Checking source", "arrow.triangle.2.circlepath", .inProgress)
            case .ready: resolved = ("Ready to download", "checkmark.circle", .success)
            case .unavailable: resolved = ("Source unavailable", "exclamationmark.triangle", .failure)
            case .invalidLink: resolved = ("Invalid link", "exclamationmark.circle", .failure)
            }
        }
        text = resolved.0; systemImage = resolved.1; role = resolved.2
        accessibilityLabel = "Source status: \(resolved.0)"
    }
}

struct SourceFact: Equatable, Identifiable { let id: String; let label: String; let value: String }

struct SourceHistoryItem: Equatable, Identifiable {
    let id: URL
    let title: String
    let savedText: String

    static func recent(from tracks: [DownloadedTrack], limit: Int = 3) -> [SourceHistoryItem] {
        guard limit > 0 else { return [] }
        return tracks
            .sorted { $0.savedAt > $1.savedAt }
            .prefix(limit)
            .map {
                SourceHistoryItem(
                    id: $0.fileURL,
                    title: $0.title,
                    savedText: $0.savedAt.formatted(date: .abbreviated, time: .omitted)
                )
            }
    }
}
