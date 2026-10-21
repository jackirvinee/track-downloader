import TrackDownloaderCore
import Foundation

struct DownloadedTrackScanResult: Equatable, Sendable {
    let tracks: [DownloadedTrack]
    let isOutputDirectoryAvailable: Bool
}

protocol DownloadedTrackScanning: Sendable {
    func scan(in outputDirectory: URL) -> DownloadedTrackScanResult
}

struct DownloadedTrackScanner: DownloadedTrackScanning {
    private static let supportedAudioExtensions: Set<String> = [
        "aac", "aiff", "alac", "flac", "m4a", "mp3",
        "oga", "ogg", "opus", "wav", "webm"
    ]

    func scan(in outputDirectory: URL) -> DownloadedTrackScanResult {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                at: outputDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [],
                errorHandler: { _, _ in false }
              ) else {
            return DownloadedTrackScanResult(tracks: [], isOutputDirectoryAvailable: false)
        }

        let resolvedRoot = outputDirectory.resolvingSymlinksInPath().standardizedFileURL
        var tracks: [DownloadedTrack] = []

        for case let fileURL as URL in enumerator {
            let resolvedFileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
            guard isWithinOutputRoot(resolvedFileURL, root: resolvedRoot),
                  Self.supportedAudioExtensions.contains(fileURL.pathExtension.lowercased()),
                  let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
                  ),
                  values.isRegularFile == true else {
                continue
            }

            tracks.append(
                DownloadedTrack(
                    fileURL: fileURL,
                    metadata: metadata(for: fileURL, root: resolvedRoot),
                    savedAt: values.contentModificationDate ?? .distantPast,
                    fileSizeBytes: values.fileSize.map(Int64.init),
                    relativeDirectory: relativeDirectory(for: fileURL, root: outputDirectory)
                )
            )
        }

        return DownloadedTrackScanResult(
            tracks: tracks.sorted {
                if $0.savedAt != $1.savedAt {
                    return $0.savedAt > $1.savedAt
                }
                return $0.fileURL.path < $1.fileURL.path
            },
            isOutputDirectoryAvailable: true
        )
    }

    private func metadata(for fileURL: URL, root: URL) -> TrackMetadata? {
        let sidecarURLs = [
            fileURL.deletingPathExtension().appendingPathExtension("info.json"),
            fileURL.appendingPathExtension("info.json")
        ]

        for sidecarURL in sidecarURLs {
            let resolvedSidecarURL = sidecarURL.resolvingSymlinksInPath().standardizedFileURL
            guard isWithinOutputRoot(resolvedSidecarURL, root: root) else {
                continue
            }
            if let data = try? Data(contentsOf: resolvedSidecarURL),
               let metadata = TrackMetadata.decode(from: data) {
                return metadata
            }
        }
        return nil
    }

    private func isWithinOutputRoot(_ candidate: URL, root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private func relativeDirectory(for fileURL: URL, root: URL) -> String? {
        let parent = fileURL.deletingLastPathComponent().standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard parent != rootPath, parent.hasPrefix(rootPath + "/") else { return nil }
        return String(parent.dropFirst(rootPath.count + 1))
    }
}
