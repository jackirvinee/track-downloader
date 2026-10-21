import Foundation

public enum URLValidationError: LocalizedError, Equatable {
    case invalid
    case unsupportedHost

    public var errorDescription: String? {
        switch self {
        case .invalid:
            return "Paste a valid YouTube or SoundCloud link."
        case .unsupportedHost:
            return "This app supports YouTube and SoundCloud links."
        }
    }
}

public enum URLValidator {
    private static let supportedHosts = [
        "youtube.com",
        "youtu.be",
        "soundcloud.com"
    ]

    public static func normalize(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "https",
            let host = components.host?.lowercased(),
            components.user == nil,
            components.password == nil,
            let url = components.url
        else {
            throw URLValidationError.invalid
        }

        guard supportedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
            throw URLValidationError.unsupportedHost
        }
        return url
    }
}
