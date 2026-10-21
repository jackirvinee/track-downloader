import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ChromeQueueEnqueueResult: Equatable {
    case queued
    case duplicate
}

public enum ChromeCompanionQueueError: Error, Equatable {
    case capacityReached
    case unreadableQueue
}

public enum ChromeCompanionQueueStatus: Codable, Equatable, Sendable {
    case queued
    case failed(String)
}

public struct ChromeCompanionQueueEntry: Codable, Equatable, Identifiable, Sendable {
    public let request: ChromeCompanionRequest
    public var status: ChromeCompanionQueueStatus

    public var id: UUID { request.requestID }

    public init(request: ChromeCompanionRequest, status: ChromeCompanionQueueStatus = .queued) {
        self.request = request
        self.status = status
    }
}

public struct ChromeCompanionQueue {
    public static let maximumRequestCount = 20
    private static let maximumQueueBytes = 262_144

    public let fileURL: URL

    public init(fileURL: URL = ChromeCompanionQueue.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public func enqueue(_ request: ChromeCompanionRequest) throws -> ChromeQueueEnqueueResult {
        try withExclusiveLock {
            guard request.isValidForQueuePersistence() else {
                throw ChromeCompanionQueueError.unreadableQueue
            }
            var current = try loadUnlocked()
            if current.contains(where: {
                $0.request.requestID == request.requestID || $0.request.url == request.url
            }) {
                return .duplicate
            }
            guard current.count < Self.maximumRequestCount else {
                throw ChromeCompanionQueueError.capacityReached
            }
            current.append(ChromeCompanionQueueEntry(request: request))
            try persistUnlocked(current)
            return .queued
        }
    }

    public func entries() throws -> [ChromeCompanionQueueEntry] {
        try withExclusiveLock { try loadUnlocked() }
    }

    public func dequeue() throws -> ChromeCompanionRequest? {
        try withExclusiveLock {
            var current = try loadUnlocked()
            guard !current.isEmpty else { return nil }
            let request = current.removeFirst().request
            try persistUnlocked(current)
            return request
        }
    }

    public func remove(requestID: UUID) throws {
        try update { entries in
            entries.removeAll { $0.request.requestID == requestID }
        }
    }

    public func markQueued(requestID: UUID) throws {
        try update { entries in
            guard let index = entries.firstIndex(where: { $0.request.requestID == requestID }) else { return }
            entries[index].status = .queued
        }
    }

    public func markFailed(requestID: UUID, message: String) throws {
        let boundedMessage = String(
            message.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200)
        )
        try update { entries in
            guard let index = entries.firstIndex(where: { $0.request.requestID == requestID }) else { return }
            entries[index].status = .failed(boundedMessage)
        }
    }

    @discardableResult
    public func clearWaiting(excluding activeRequestID: UUID? = nil) throws -> Int {
        try withExclusiveLock {
            var current = try loadUnlocked()
            let previousCount = current.count
            current.removeAll { $0.request.requestID != activeRequestID }
            try persistUnlocked(current)
            return previousCount - current.count
        }
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("Track Downloader", isDirectory: true)
            .appendingPathComponent("Chrome Companion", isDirectory: true)
            .appendingPathComponent("pending-requests.json", isDirectory: false)
    }

    private func update(_ mutation: (inout [ChromeCompanionQueueEntry]) -> Void) throws {
        try withExclusiveLock {
            var current = try loadUnlocked()
            mutation(&current)
            try persistUnlocked(current)
        }
    }

    private func loadUnlocked() throws -> [ChromeCompanionQueueEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= Self.maximumQueueBytes else {
                throw ChromeCompanionQueueError.unreadableQueue
            }
            if let document = try? JSONDecoder().decode(QueueDocument.self, from: data),
               document.version == QueueDocument.currentVersion,
               isValid(document.entries) {
                return document.entries
            }
            if let legacy = try? JSONDecoder().decode([ChromeCompanionRequest].self, from: data) {
                let entries = legacy.map { ChromeCompanionQueueEntry(request: $0) }
                guard isValid(entries) else { throw ChromeCompanionQueueError.unreadableQueue }
                return entries
            }
            throw ChromeCompanionQueueError.unreadableQueue
        } catch let error as ChromeCompanionQueueError {
            throw error
        } catch {
            throw ChromeCompanionQueueError.unreadableQueue
        }
    }

    private func persistUnlocked(_ entries: [ChromeCompanionQueueEntry]) throws {
        do {
            let data = try JSONEncoder().encode(QueueDocument(entries: entries))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ChromeCompanionQueueError.unreadableQueue
        }
    }

    private func isValid(_ entries: [ChromeCompanionQueueEntry]) -> Bool {
        guard entries.count <= Self.maximumRequestCount,
              Set(entries.map(\.id)).count == entries.count,
              Set(entries.map { $0.request.url }).count == entries.count,
              entries.allSatisfy({ $0.request.isValidForQueuePersistence() }) else {
            return false
        }
        return entries.allSatisfy { entry in
            if case .failed(let message) = entry.status {
                return !message.isEmpty && message.count <= 200
                    && !message.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }
            return true
        }
    }

    private func withExclusiveLock<T>(_ operation: () throws -> T) throws -> T {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ChromeCompanionQueueError.unreadableQueue
        }

        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ChromeCompanionQueueError.unreadableQueue }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ChromeCompanionQueueError.unreadableQueue
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

private struct QueueDocument: Codable {
    static let currentVersion = 1

    let version: Int
    let entries: [ChromeCompanionQueueEntry]

    init(entries: [ChromeCompanionQueueEntry]) {
        self.version = Self.currentVersion
        self.entries = entries
    }
}
