import Foundation

public enum DownloadStage: String, Equatable, Sendable {
    case validating
    case resolving
    case downloading
    case processing
    case measuringQuality
}

public struct DownloadProgress: Equatable, Sendable {
    public let stage: DownloadStage
    public let fractionCompleted: Double?
    public let detail: String?

    public init(stage: DownloadStage, fractionCompleted: Double?, detail: String?) {
        self.stage = stage
        self.fractionCompleted = fractionCompleted
        self.detail = detail
    }
}

public enum YTDLPOutputEvent: Equatable, Sendable {
    case progress(percent: Double, speed: String?, eta: String?)
    case postProcess(name: String?)
    case finalPath(String)
    case diagnostic(String)
}

public enum YTDLPOutputParser {
    public static func parse(line: String) -> YTDLPOutputEvent {
        if let record = line.record(after: "track-downloader:progress:"),
           let progress = parseProgress(record) {
            return progress
        }

        if let record = line.record(after: "track-downloader:postprocess:") {
            return .postProcess(name: optionalRecordValue(record))
        }

        if let record = line.record(after: "track-downloader:filepath:"), !record.isEmpty {
            return .finalPath(record)
        }

        return .diagnostic(line)
    }

    private static func parseProgress(_ record: String) -> YTDLPOutputEvent? {
        let fields = record.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let percent = percent(from: String(fields[0])) else {
            return nil
        }

        return .progress(
            percent: min(max(percent, 0), 100),
            speed: optionalRecordValue(String(fields[1])),
            eta: optionalRecordValue(String(fields[2]))
        )
    }

    private static func percent(from value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = trimmed.hasSuffix("%") ? String(trimmed.dropLast()) : trimmed
        return Double(number.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func optionalRecordValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    func record(after prefix: String) -> String? {
        guard hasPrefix(prefix) else {
            return nil
        }
        return String(dropFirst(prefix.count))
    }
}
