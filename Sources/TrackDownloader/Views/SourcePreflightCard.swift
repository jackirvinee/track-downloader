import Foundation
import SwiftUI
import TrackDownloaderCore

struct SourcePreflightPresentation: Equatable {
    let title: String
    let facts: [SourceFact]
    let assessment: String

    // Compatibility accessors retain the existing sanitization test coverage while views use facts.
    var secondaryText: String? {
        let values = facts.filter { $0.id == "uploader" || $0.id == "duration" }.map(\.value)
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }
    var audioText: String? {
        let values = facts.filter { $0.id == "codec" || $0.id == "bitrate" || $0.id == "sample-rate" }.map { fact in
            fact.id == "bitrate" ? "Estimated \(fact.value)" : fact.value
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    init(result: SourcePreflightResult) {
        title = Self.sourceText(result.title, maximumLength: 160) ?? "Source available"

        var facts: [SourceFact] = []
        if let uploader = Self.sourceText(result.uploader, maximumLength: 120) {
            facts.append(.init(id: "uploader", label: "Uploader", value: uploader))
        }
        if let duration = Self.durationText(seconds: result.durationSeconds) {
            facts.append(.init(id: "duration", label: "Duration", value: duration))
        }
        if let codec = Self.sourceText(result.selectedAudio.codec, maximumLength: 32) {
            facts.append(.init(id: "codec", label: "Codec estimate", value: codec.capitalized))
        }
        if let bitrate = result.selectedAudio.bitrateKbps, bitrate > 0 {
            facts.append(.init(id: "bitrate", label: "Bitrate estimate", value: "\(bitrate) kbps"))
        }
        if let sampleRate = result.selectedAudio.sampleRateHz, sampleRate > 0 {
            facts.append(.init(id: "sample-rate", label: "Sample-rate estimate", value: Self.sampleRateText(hertz: sampleRate)))
        }
        self.facts = facts
        assessment = result.assessment.title
    }

    static func unavailableMessage(_: String) -> String {
        "This source could not be checked right now."
    }

    private static func sourceText(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        guard !containsUnsafeControlCharacters(value) else { return nil }
        let withoutControls = value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let normalized = withoutControls
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty, !looksLikeDiagnosticOrURL(normalized) else { return nil }
        return String(normalized.prefix(maximumLength))
    }

    private static func looksLikeDiagnosticOrURL(_ value: String) -> Bool {
        let normalized = value.lowercased()
        let blockedMarkers = [
            "://",
            "yt-dlp", "ffmpeg", "ffprobe", "deno", "cookie",
            "error:", "warning:", "fatal:", "panic:", "traceback", "exception",
            "command not found", "stack trace", "stderr:", "stdout:", "exit code",
            "no such file", "permission denied", "--", "/usr/", "/opt/", "/bin/",
        ]
        return blockedMarkers.contains { normalized.contains($0) }
            || containsURIScheme(normalized)
            || containsBareDomain(normalized)
            || containsToolDiagnostic(normalized)
    }

    private static func containsUnsafeControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                && ![9, 10, 13].contains(Int(scalar.value))
        }
    }

    private static func containsBareDomain(_ value: String) -> Bool {
        value.range(
            of: #"(?:^|[\s(/])(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:[/?:#]|\b)"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsURIScheme(_ value: String) -> Bool {
        value.range(
            of: #"(?:^|[^a-z0-9+.-])[a-z][a-z0-9+.-]*:\S"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsToolDiagnostic(_ value: String) -> Bool {
        let patterns = [
            #"(?:^|\s)(?:sh|bash|zsh):\s+command not found:"#,
            #"(?:^|\s)curl:\s+\(\d+\)\s+"#
        ]
        return patterns.contains { pattern in
            value.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func durationText(seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainder = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    private static func sampleRateText(hertz: Int) -> String {
        let kilohertz = Double(hertz) / 1_000
        if kilohertz.rounded() == kilohertz {
            return "\(Int(kilohertz)) kHz"
        }
        return String(format: "%.1f kHz", kilohertz)
    }
}

struct SourcePreflightCard: View {
    let state: SourcePreflightState
    let download: () -> Void
    let checkAgain: () -> Void
    var downloadEnabled = true

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .invalidLink(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(message)
        case .checking:
            ProgressView("Checking source")
                .controlSize(.small)
                .font(.caption)
                .accessibilityLabel("Checking source without downloading media")
        case .ready(let result):
            readyCard(SourcePreflightPresentation(result: result))
        case .unavailable(let message):
            unavailableCard(SourcePreflightPresentation.unavailableMessage(message))
        }
    }

    private func readyCard(_ presentation: SourcePreflightPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
                Text(presentation.title)
                    .font(.headline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(presentation.facts) { fact in
                        GridRow { Text(fact.label).foregroundStyle(.secondary); Text(fact.value).textSelection(.enabled) }
                    }
                    GridRow { Text("Assessment").foregroundStyle(.secondary); Text(presentation.assessment).fontWeight(.medium) }
                }
                Button("Download", systemImage: "arrow.down.circle", action: download)
                    .buttonStyle(.borderedProminent)
                    .disabled(!downloadEnabled)
                    .accessibilityHint("Starts the selected media download after this source check.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source check complete. \(presentation.title). \(presentation.assessment).")
    }

    private func unavailableCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Check again", action: checkAgain)
                    .buttonStyle(.bordered)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }

}
