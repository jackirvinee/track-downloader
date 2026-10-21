import TrackDownloaderCore
import Darwin
import Foundation

struct DownloaderService {
    static let defaultOutputDirectory = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Track Downloader", isDirectory: true)

    let outputDirectory: URL
    private let processRunner: any ProcessRunning
    private let toolResolver: @Sendable (String) throws -> URL

    init(
        outputDirectory: URL = DownloaderService.defaultOutputDirectory,
        processRunner: any ProcessRunning = ProcessRunner(),
        toolResolver: @escaping @Sendable (String) throws -> URL = { try ToolResolver.resolve($0) }
    ) {
        self.outputDirectory = outputDirectory
        self.processRunner = processRunner
        self.toolResolver = toolResolver
    }

    func download(
        sourceURL: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> DownloadResult {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let fileAccess = try OutputDirectoryFileAccess(rootDirectory: outputDirectory)

        let ytDLP = try resolveTool(named: "yt-dlp")
        let ffmpeg = try resolveTool(named: "ffmpeg")
        let deno = try resolveTool(named: "deno")
        let arguments = DownloadCommandBuilder.arguments(
            sourceURL: sourceURL,
            outputDirectory: outputDirectory,
            ffmpegPath: ffmpeg.path,
            denoPath: deno.path
        )
        let finalPath = FinalPathRecorder()
        onProgress(DownloadProgress(stage: .resolving, fractionCompleted: nil, detail: nil))
        let download = try await processRunner.run(
            executable: ytDLP,
            arguments: arguments,
            onLine: { line in
                switch YTDLPOutputParser.parse(line: line) {
                case let .progress(percent, speed, eta):
                    onProgress(
                        DownloadProgress(
                            stage: .downloading,
                            fractionCompleted: percent / 100,
                            detail: [speed, eta].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
                        )
                    )
                case let .postProcess(name):
                    onProgress(
                        DownloadProgress(stage: .processing, fractionCompleted: nil, detail: name)
                    )
                case let .finalPath(path):
                    finalPath.record(path)
                case .diagnostic:
                    break
                }
            }
        )
        try append(
            download.output,
            to: outputDirectory.appendingPathComponent("track-downloader-last-download.log"),
            using: fileAccess
        )

        guard download.exitCode == 0 else {
            throw DownloadFailurePresentation(
                kind: .extractor,
                title: "Download failed",
                message: extractorMessage(from: download.output),
                technicalDetails: download.output.nilIfEmpty
            )
        }

        guard let fileURL = downloadedFile(from: finalPath.value ?? download.output) else {
            if hasExplicitArchiveEvidence(in: download.output) {
                throw DownloadFailurePresentation(
                    kind: .alreadyInCollection,
                    title: "Previously downloaded",
                    message: "No new file was created. This link appears in Track Downloader's download history; check your local collection.",
                    technicalDetails: nil
                )
            }
            throw DownloadFailurePresentation(
                kind: .outputFileMissing,
                title: "No downloaded file found",
                message: "The download finished, but no audio file was reported.",
                technicalDetails: nil
            )
        }

        let ffprobe = try resolveTool(named: "ffprobe")
        let metadata: TrackMetadata
        let quality: AudioQuality
        do {
            (metadata, quality) = try await fileAccess.withRegularFile(at: fileURL) { mediaHandle in
                let metadata = self.metadata(for: fileURL, using: fileAccess)
                onProgress(DownloadProgress(stage: .measuringQuality, fractionCompleted: nil, detail: nil))
                let quality = try await inspectQuality(
                    of: fileURL,
                    ffprobe: ffprobe,
                    standardInput: mediaHandle
                )
                return (metadata, quality)
            }
        } catch let failure as DownloadFailurePresentation {
            throw failure
        } catch {
            throw DownloadFailurePresentation(
                kind: .outputFileMissing,
                title: "No downloaded file found",
                message: "The download finished, but no audio file was reported.",
                technicalDetails: nil
            )
        }
        let report = "\(timestamp()) \(fileURL.lastPathComponent) | \(quality.reportLine)\n"
        try append(
            report,
            to: outputDirectory.appendingPathComponent("track-downloader-quality-report.txt"),
            using: fileAccess
        )
        return DownloadResult(fileURL: fileURL, metadata: metadata, quality: quality)
    }

    func cancel() {
        processRunner.cancel()
    }

    private func inspectQuality(
        of fileURL: URL,
        ffprobe: URL,
        standardInput: FileHandle
    ) async throws -> AudioQuality {
        let result: CommandResult
        do {
            result = try await processRunner.run(
                executable: ffprobe,
                arguments: [
                    "-v", "error",
                    "-show_entries",
                    "stream=codec_type,codec_name,bit_rate,sample_rate:format=bit_rate",
                    "-of", "json",
                    "pipe:0"
                ],
                standardInput: standardInput,
                onLine: { _ in }
            )
        } catch {
            throw qualityUnavailable(details: error.localizedDescription)
        }

        guard result.exitCode == 0 else {
            throw qualityUnavailable(details: result.output.nilIfEmpty)
        }
        do {
            return try AudioQualityParser.parse(Data(result.output.utf8), fileURL: fileURL)
        } catch {
            throw qualityUnavailable(details: result.output.nilIfEmpty ?? error.localizedDescription)
        }
    }

    private func resolveTool(named name: String) throws -> URL {
        do {
            return try toolResolver(name)
        } catch {
            let installCommand = installCommand(for: name)
            throw DownloadFailurePresentation(
                kind: .missingDependency(
                    name: name,
                    installCommand: installCommand
                ),
                title: "Missing \(name)",
                message: "Install it with Homebrew, then try again.",
                technicalDetails: installCommand
            )
        }
    }

    private func installCommand(for tool: String) -> String {
        tool == "deno" ? "brew install deno" : "brew install yt-dlp ffmpeg"
    }

    private func qualityUnavailable(details: String?) -> DownloadFailurePresentation {
        DownloadFailurePresentation(
            kind: .qualityUnavailable,
            title: "Quality unavailable",
            message: "The track downloaded, but its audio quality could not be measured.",
            technicalDetails: details
        )
    }

    private func downloadedFile(from output: String) -> URL? {
        if case let .finalPath(path) = YTDLPOutputParser.parse(line: output) {
            if let candidate = containedOutputFileURL(for: path) {
                return candidate
            }
        }

        let extensions = Set([
            "aac", "aiff", "alac", "flac", "m4a", "mp3",
            "oga", "ogg", "opus", "wav", "webm"
        ])

        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
                continue
            }

            if let candidate = containedOutputFileURL(for: path) {
                return candidate
            }
        }
        return nil
    }

    private func containedOutputFileURL(for path: String) -> URL? {
        containedOutputURL(URL(fileURLWithPath: path, relativeTo: outputDirectory))
    }

    private func containedOutputURL(_ fileURL: URL) -> URL? {
        let root = outputDirectory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = fileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidate.pathComponents.starts(with: root.pathComponents) else {
            return nil
        }
        return candidate.pathComponents
            .dropFirst(root.pathComponents.count)
            .reduce(outputDirectory) { partialURL, component in
                partialURL.appendingPathComponent(component)
            }
    }

    private func metadata(for fileURL: URL, using fileAccess: OutputDirectoryFileAccess) -> TrackMetadata {
        let sidecarURLs = [
            fileURL.deletingPathExtension().appendingPathExtension("info.json"),
            fileURL.appendingPathExtension("info.json")
        ]

        for sidecarURL in sidecarURLs {
            if let data = try? fileAccess.readRegularFile(at: sidecarURL),
               let metadata = TrackMetadata.decode(from: data) {
                return metadata
            }
        }

        return TrackMetadata(title: fileURL.deletingPathExtension().lastPathComponent)
    }

    private func hasExplicitArchiveEvidence(in output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.hasPrefix("[download]") else { return false }
            guard !normalized.hasPrefix("[download] destination:") else { return false }
            return normalized.hasSuffix(" has already been recorded in the archive")
                || normalized.hasSuffix(" has already been downloaded")
        }
    }

    private func extractorMessage(from output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let detail = lines.last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("ERROR:") })
            ?? lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? "yt-dlp could not download this track."
        return detail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ERROR:", with: "", options: [.caseInsensitive, .anchored])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func append(_ text: String, to fileURL: URL, using fileAccess: OutputDirectoryFileAccess) throws {
        try fileAccess.append(Data(text.redactedForPersistence.utf8), to: fileURL)
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "[\(formatter.string(from: Date()))]"
    }
}

private final class OutputDirectoryFileAccess {
    private let rootDirectory: URL
    private let rootDescriptor: Int32

    init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        rootDescriptor = try Self.openRootDirectory(at: rootDirectory)
    }

    deinit {
        _ = Darwin.close(rootDescriptor)
    }

    func readRegularFile(at fileURL: URL) throws -> Data {
        try withRegularFileDescriptor(at: fileURL, flags: O_RDONLY) { descriptor in
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            return try handle.readToEnd() ?? Data()
        }
    }

    func append(_ data: Data, to fileURL: URL) throws {
        try withRegularFileDescriptor(
            at: fileURL,
            flags: O_WRONLY | O_APPEND | O_CREAT,
            mode: 0o644
        ) { descriptor in
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            try handle.write(contentsOf: data)
        }
    }

    func withRegularFile<T>(
        at fileURL: URL,
        _ body: (FileHandle) async throws -> T
    ) async throws -> T {
        let descriptor = try openRegularFileDescriptor(at: fileURL, flags: O_RDONLY)
        defer { _ = Darwin.close(descriptor) }
        return try await body(FileHandle(fileDescriptor: descriptor, closeOnDealloc: false))
    }

    private func withRegularFileDescriptor<T>(
        at fileURL: URL,
        flags: Int32,
        mode: mode_t? = nil,
        _ body: (Int32) throws -> T
    ) throws -> T {
        let fileDescriptor = try openRegularFileDescriptor(at: fileURL, flags: flags, mode: mode)
        defer { _ = Darwin.close(fileDescriptor) }
        return try body(fileDescriptor)
    }

    private func openRegularFileDescriptor(
        at fileURL: URL,
        flags: Int32,
        mode: mode_t? = nil
    ) throws -> Int32 {
        let components = try relativePathComponents(for: fileURL)
        var parentDescriptor = rootDescriptor
        var openedParentDescriptors: [Int32] = []
        defer { openedParentDescriptors.forEach { _ = Darwin.close($0) } }

        for component in components.dropLast() {
            let descriptor = try openDirectory(at: parentDescriptor, named: component)
            openedParentDescriptors.append(descriptor)
            parentDescriptor = descriptor
        }

        let fileDescriptor = try openFile(
            at: parentDescriptor,
            named: components.last!,
            flags: flags | O_NOFOLLOW | O_CLOEXEC,
            mode: mode
        )

        var status = stat()
        guard Darwin.fstat(fileDescriptor, &status) == 0 else {
            _ = Darwin.close(fileDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.close(fileDescriptor)
            throw POSIXError(.EACCES)
        }

        return fileDescriptor
    }

    private func relativePathComponents(for fileURL: URL) throws -> [String] {
        let rootComponents = rootDirectory.pathComponents
        let candidateComponents = fileURL.pathComponents
        guard candidateComponents.starts(with: rootComponents) else {
            throw POSIXError(.EACCES)
        }
        let components = Array(candidateComponents.dropFirst(rootComponents.count))
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw POSIXError(.EACCES)
        }
        return components
    }

    private static func openRootDirectory(at rootDirectory: URL) throws -> Int32 {
        let resolvedRoot = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
        var expectedStatus = stat()
        let lstatResult = resolvedRoot.path.withCString { Darwin.lstat($0, &expectedStatus) }
        guard lstatResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard expectedStatus.st_mode & S_IFMT == S_IFDIR else {
            throw POSIXError(.EACCES)
        }

        let descriptor = try openDirectory(atPath: resolvedRoot.path)
        var actualStatus = stat()
        guard Darwin.fstat(descriptor, &actualStatus) == 0 else {
            _ = Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard actualStatus.st_mode & S_IFMT == S_IFDIR,
              actualStatus.st_dev == expectedStatus.st_dev,
              actualStatus.st_ino == expectedStatus.st_ino else {
            _ = Darwin.close(descriptor)
            throw POSIXError(.EACCES)
        }
        return descriptor
    }

    private static func openDirectory(atPath path: String) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let descriptor = path.withCString { Darwin.open($0, flags) }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }

    private func openDirectory(at descriptor: Int32, named name: String) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let childDescriptor = name.withCString { Darwin.openat(descriptor, $0, flags) }
        guard childDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return childDescriptor
    }

    private func openFile(at descriptor: Int32, named name: String, flags: Int32, mode: mode_t?) throws -> Int32 {
        let fileDescriptor = name.withCString { name in
            if let mode {
                return Darwin.openat(descriptor, name, flags, mode)
            }
            return Darwin.openat(descriptor, name, flags)
        }
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fileDescriptor
    }
}

private final class FinalPathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPath: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return recordedPath
    }

    func record(_ path: String) {
        lock.lock()
        recordedPath = path
        lock.unlock()
    }
}

private extension String {
    var redactedForPersistence: String {
        replacingOccurrences(
            of: #"(?i)\bhttps?://[^\s<>\"']+"#,
            with: "[REDACTED_URL]",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"(?im)\b(authorization|cookie|x-api-key|api[-_ ]?token)\b\s*[:=]\s*[^\r\n]*"#,
            with: "$1: [REDACTED]",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#,
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension DownloaderService: DownloadServicing {}
