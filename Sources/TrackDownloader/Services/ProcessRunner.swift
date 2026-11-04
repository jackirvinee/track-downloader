import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let output: String
}

protocol ProcessRunning: AnyObject, Sendable {
    func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult
    func run(
        executable: URL,
        arguments: [String],
        standardInput: FileHandle?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult
    func cancel()
}

final class ProcessRunner: ProcessRunning, @unchecked Sendable {
    /// How long an interrupted child gets to clean up before it is terminated.
    static let interruptGracePeriod: TimeInterval = 3

    private let stateLock = NSLock()
    private var activeProcess: Process?

    func run(
        executable: URL,
        arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        try await run(
            executable: executable,
            arguments: arguments,
            standardInput: nil,
            onLine: onLine
        )
    }

    func run(
        executable: URL,
        arguments: [String],
        standardInput: FileHandle?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        let launch = ProcessLaunch()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let pipe = Pipe()
                let fileHandle = pipe.fileHandleForReading
                let collector = OutputCollector(onLine: onLine)
                let outputReader = ProcessOutputReader(fileHandle: fileHandle, collector: collector)

                process.executableURL = executable
                process.arguments = arguments
                process.standardInput = standardInput
                process.standardOutput = pipe
                process.standardError = pipe

                outputReader.start()

                process.terminationHandler = { [self] terminatedProcess in
                    outputReader.finish { output in
                        self.clearActiveProcess(terminatedProcess)
                        continuation.resume(
                            returning: CommandResult(
                                exitCode: terminatedProcess.terminationStatus,
                                output: String(decoding: output, as: UTF8.self)
                            )
                        )
                    }
                }

                // Launch while holding the lock so a concurrent cancellation either
                // marks this launch cancelled before it starts or finds a process
                // that is already running; it can no longer fall between the two.
                stateLock.lock()
                if launch.isCancelled {
                    stateLock.unlock()
                    outputReader.close()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                activeProcess = process
                launch.process = process
                var launchError: Error?
                do {
                    try process.run()
                } catch {
                    launchError = error
                }
                stateLock.unlock()

                if let launchError {
                    outputReader.close()
                    clearActiveProcess(process)
                    continuation.resume(throwing: launchError)
                }
            }
        } onCancel: {
            self.stateLock.lock()
            launch.isCancelled = true
            let process = launch.process
            self.stateLock.unlock()

            if let process {
                Self.stop(process)
            }
        }
    }

    func cancel() {
        stateLock.lock()
        let process = activeProcess
        stateLock.unlock()

        if let process {
            Self.stop(process)
        }
    }

    /// Interrupts first, like Control-C, so yt-dlp can stop the ffmpeg child it
    /// started; a plain terminate kills yt-dlp and leaves ffmpeg running.
    /// Terminates if the child is still running after the grace period.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + interruptGracePeriod) { [weak process] in
            if process?.isRunning == true {
                process?.terminate()
            }
        }
    }

    static func run(executable: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    private func clearActiveProcess(_ process: Process) {
        stateLock.lock()
        if activeProcess === process {
            activeProcess = nil
        }
        stateLock.unlock()
    }
}

/// Per-run cancellation state, guarded by `ProcessRunner.stateLock`.
private final class ProcessLaunch: @unchecked Sendable {
    var isCancelled = false
    var process: Process?
}

private final class ProcessOutputReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let collector: OutputCollector
    private let queue = DispatchQueue(label: "com.jackirvine.trackdownloader.process-runner.output")
    private var isClosed = false

    init(fileHandle: FileHandle, collector: OutputCollector) {
        self.fileHandle = fileHandle
        self.collector = collector
    }

    func start() {
        fileHandle.readabilityHandler = { [weak self] _ in
            self?.queue.async {
                self?.readAvailableData()
            }
        }
    }

    func finish(_ completion: @escaping @Sendable (Data) -> Void) {
        queue.async { [self] in
            guard !isClosed else { return }

            fileHandle.readabilityHandler = nil
            collector.append(fileHandle.readDataToEndOfFile())
            isClosed = true
            try? fileHandle.close()
            completion(collector.finish())
        }
    }

    func close() {
        queue.sync { [self] in
            guard !isClosed else { return }

            fileHandle.readabilityHandler = nil
            isClosed = true
            try? fileHandle.close()
        }
    }

    private func readAvailableData() {
        guard !isClosed else { return }
        collector.append(fileHandle.availableData)
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void
    private var output = Data()
    private var pendingLine = Data()

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        output.append(data)
        pendingLine.append(data)
        deliverCompleteLines()
        lock.unlock()
    }

    func finish() -> Data {
        lock.lock()
        defer { lock.unlock() }

        if !pendingLine.isEmpty {
            deliverLine(pendingLine)
            pendingLine.removeAll(keepingCapacity: false)
        }
        return output
    }

    private func deliverCompleteLines() {
        while let newline = pendingLine.firstIndex(of: 0x0A) {
            let line = pendingLine[..<newline]
            pendingLine.removeSubrange(...newline)
            deliverLine(Data(line))
        }
    }

    private func deliverLine(_ data: Data) {
        var line = String(decoding: data, as: UTF8.self)
        if line.last == "\r" {
            line.removeLast()
        }
        onLine(line)
    }
}
