import Foundation
import TrackDownloaderCore

public enum ChromeCompanionAction: String, Codable, Equatable, Sendable {
    case enqueueDownload
}

public enum ChromeCompanionPlatform: String, Codable, Equatable, Sendable {
    case youtube
    case soundcloud

    static func platform(for url: URL) -> ChromeCompanionPlatform? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "youtu.be" || host.hasSuffix(".youtu.be")
            || host == "youtube.com" || host.hasSuffix(".youtube.com") {
            return .youtube
        }
        if host == "soundcloud.com" || host.hasSuffix(".soundcloud.com") {
            return .soundcloud
        }
        return nil
    }
}

public struct ChromeCompanionMetadata: Codable, Equatable, Sendable {
    public static let maximumTitleLength = 160
    public static let maximumCreatorLength = 120

    public let title: String?
    public let creator: String?
    public let platform: ChromeCompanionPlatform

    init(title: String?, creator: String?, platform: ChromeCompanionPlatform) throws {
        self.title = try Self.normalized(title, maximumLength: Self.maximumTitleLength)
        self.creator = try Self.normalized(creator, maximumLength: Self.maximumCreatorLength)
        self.platform = platform
    }

    private static func normalized(_ value: String?, maximumLength: Int) throws -> String? {
        guard let value else { return nil }
        guard value.count <= maximumLength,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ChromeCompanionRequestError.invalidMetadata
        }
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

public enum ChromeCompanionRequestError: Error, Equatable {
    case oversized
    case invalidEnvelope
    case unsupportedVersion
    case invalidRequestID
    case unsupportedAction
    case invalidTimestamp
    case expiredTimestamp
    case futureTimestamp
    case unsupportedURL
    case invalidMetadata
}

public struct ChromeCompanionRequest: Codable, Equatable, Sendable {
    public static let maximumMessageBytes = 4_096
    public static let protocolVersion = 2

    public let requestID: UUID
    public let action: ChromeCompanionAction
    public let url: URL
    public let issuedAtMs: Int64
    public let metadata: ChromeCompanionMetadata?

    public init(
        requestID: UUID,
        action: ChromeCompanionAction = .enqueueDownload,
        url: URL,
        issuedAtMs: Int64,
        metadata: ChromeCompanionMetadata? = nil
    ) {
        self.requestID = requestID
        self.action = action
        self.url = url
        self.issuedAtMs = issuedAtMs
        self.metadata = metadata
    }

    public static func decode(_ data: Data, now: Date = .now) throws -> ChromeCompanionRequest {
        guard data.count <= maximumMessageBytes else {
            throw ChromeCompanionRequestError.oversized
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let version = dictionary["version"] as? Int
        else {
            throw ChromeCompanionRequestError.invalidEnvelope
        }

        let expectedKeys: Set<String>
        switch version {
        case 1:
            expectedKeys = ["version", "requestId", "action", "url", "issuedAtMs"]
        case protocolVersion:
            expectedKeys = ["version", "requestId", "action", "url", "issuedAtMs", "metadata"]
        default:
            throw ChromeCompanionRequestError.unsupportedVersion
        }
        guard Set(dictionary.keys) == expectedKeys else {
            throw ChromeCompanionRequestError.invalidEnvelope
        }
        guard let requestIDString = dictionary["requestId"] as? String,
              let requestID = UUID(uuidString: requestIDString) else {
            throw ChromeCompanionRequestError.invalidRequestID
        }
        guard let actionString = dictionary["action"] as? String,
              let action = ChromeCompanionAction(rawValue: actionString) else {
            throw ChromeCompanionRequestError.unsupportedAction
        }
        guard let urlString = dictionary["url"] as? String else {
            throw ChromeCompanionRequestError.unsupportedURL
        }
        guard let issuedAtMs = dictionary["issuedAtMs"] as? Int64
            ?? (dictionary["issuedAtMs"] as? NSNumber)?.int64Value else {
            throw ChromeCompanionRequestError.invalidTimestamp
        }

        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        guard issuedAtMs >= nowMs - 7 * 24 * 60 * 60 * 1_000 else {
            throw ChromeCompanionRequestError.expiredTimestamp
        }
        guard issuedAtMs <= nowMs + 10 * 60 * 1_000 else {
            throw ChromeCompanionRequestError.futureTimestamp
        }
        guard let normalizedURL = try? URLValidator.normalize(urlString),
              let platform = ChromeCompanionPlatform.platform(for: normalizedURL),
              isIndividualItemURL(normalizedURL, platform: platform),
              let canonicalURL = canonicalURL(normalizedURL, platform: platform) else {
            throw ChromeCompanionRequestError.unsupportedURL
        }

        let metadata: ChromeCompanionMetadata?
        if version == protocolVersion {
            metadata = try decodeMetadata(dictionary["metadata"], expectedPlatform: platform)
        } else {
            metadata = nil
        }

        return ChromeCompanionRequest(
            requestID: requestID,
            action: action,
            url: canonicalURL,
            issuedAtMs: issuedAtMs,
            metadata: metadata
        )
    }

    private static func decodeMetadata(
        _ value: Any?,
        expectedPlatform: ChromeCompanionPlatform
    ) throws -> ChromeCompanionMetadata {
        guard let dictionary = value as? [String: Any],
              Set(dictionary.keys) == ["title", "creator", "platform"],
              let platformValue = dictionary["platform"] as? String,
              let platform = ChromeCompanionPlatform(rawValue: platformValue),
              platform == expectedPlatform else {
            throw ChromeCompanionRequestError.invalidMetadata
        }
        let title = try optionalString(dictionary["title"])
        let creator = try optionalString(dictionary["creator"])
        return try ChromeCompanionMetadata(title: title, creator: creator, platform: platform)
    }

    private static func optionalString(_ value: Any?) throws -> String? {
        if value is NSNull { return nil }
        guard let value = value as? String else {
            throw ChromeCompanionRequestError.invalidMetadata
        }
        return value
    }

    private static func canonicalURL(_ url: URL, platform: ChromeCompanionPlatform) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil

        switch platform {
        case .youtube:
            if components.host?.lowercased().hasSuffix("youtube.com") == true,
               components.path == "/watch",
               let videoID = components.queryItems?.first(where: { $0.name == "v" })?.value,
               !videoID.isEmpty {
                components.queryItems = [URLQueryItem(name: "v", value: videoID)]
            } else {
                components.query = nil
            }
        case .soundcloud:
            components.query = nil
            if components.path.count > 1, components.path.hasSuffix("/") {
                components.path.removeLast()
            }
        }
        return components.url
    }

    func isValidForQueuePersistence() -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let platform = ChromeCompanionPlatform.platform(for: url),
              Self.isIndividualItemURL(url, platform: platform) else {
            return false
        }
        guard let metadata else { return true }
        guard metadata.platform == platform,
              metadata.title.map({ Self.isValidPersistedText($0, maximumLength: ChromeCompanionMetadata.maximumTitleLength) }) ?? true,
              metadata.creator.map({ Self.isValidPersistedText($0, maximumLength: ChromeCompanionMetadata.maximumCreatorLength) }) ?? true else {
            return false
        }
        return true
    }

    private static func isIndividualItemURL(_ url: URL, platform: ChromeCompanionPlatform) -> Bool {
        let pathParts = url.path.split(separator: "/").map(String.init)
        switch platform {
        case .youtube:
            if url.host?.lowercased().hasSuffix("youtu.be") == true {
                return pathParts.count == 1 && !pathParts[0].isEmpty
            }
            guard url.path == "/watch",
                  let videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value else {
                return false
            }
            return !videoID.isEmpty
        case .soundcloud:
            let reserved = Set([
                "charts", "discover", "jobs", "library", "pages", "search", "settings",
                "stations", "stream", "terms", "upload", "you",
            ])
            return pathParts.count == 2 && !reserved.contains(pathParts[0].lowercased())
        }
    }

    private static func isValidPersistedText(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty
            && value.count <= maximumLength
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
