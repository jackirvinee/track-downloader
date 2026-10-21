import Foundation

/// Which browser's SoundCloud login yt-dlp borrows, read from the browser at download time.
///
/// Signed in, SoundCloud hands yt-dlp an uploader's original file when they allow downloads,
/// and a Go+ subscription adds the 256 kbps AAC stream when SoundCloud serves it without DRM.
/// yt-dlp never downloads DRM-protected streams. Nothing about the login is stored by
/// Track Downloader: only the browser name and profile are remembered.
public struct SoundCloudSignIn: Equatable, Sendable {
    /// Browsers yt-dlp can read cookies from on macOS.
    public enum Browser: String, CaseIterable, Identifiable, Sendable {
        case chrome
        case safari
        case firefox
        case brave
        case edge
        case chromium
        case opera
        case vivaldi

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .chrome: "Chrome"
            case .safari: "Safari"
            case .firefox: "Firefox"
            case .brave: "Brave"
            case .edge: "Microsoft Edge"
            case .chromium: "Chromium"
            case .opera: "Opera"
            case .vivaldi: "Vivaldi"
            }
        }

        /// Safari keeps its profiles in one cookie store, so yt-dlp ignores a profile for it.
        public var supportsProfiles: Bool { self != .safari }
    }

    public static let off = SoundCloudSignIn(browser: nil, profile: "")

    public let browser: Browser?
    public let profile: String

    public init(browser: Browser?, profile: String) {
        self.browser = browser
        self.profile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `--cookies-from-browser` value, or nil when signed out or the profile can't be passed
    /// safely. yt-dlp reads `BROWSER[+KEYRING][:PROFILE][::CONTAINER]`, so a profile containing
    /// `:` or `+` would be parsed as something else.
    public var cookiesFromBrowserValue: String? {
        guard let browser else { return nil }
        guard browser.supportsProfiles, !profile.isEmpty else { return browser.rawValue }
        guard Self.isPassableProfile(profile) else { return nil }
        return "\(browser.rawValue):\(profile)"
    }

    /// Only SoundCloud links use the login, so YouTube and other sites never see it.
    public func cookiesBrowser(for sourceURL: URL) -> String? {
        Self.isSoundCloud(sourceURL) ? cookiesFromBrowserValue : nil
    }

    public static func isPassableProfile(_ profile: String) -> Bool {
        !profile.contains(where: { $0 == ":" || $0 == "+" || $0.isNewline })
    }

    public static func isSoundCloud(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "soundcloud.com" || host.hasSuffix(".soundcloud.com")
    }
}

/// yt-dlp copies every browser cookie that matches a stream's address into that format's
/// `cookies` field, and `--write-info-json` saves it beside the track. This removes them.
public enum InfoJSONCredentialScrubber {
    private static let sensitiveHeaders: Set<String> = ["cookie", "authorization"]

    /// The JSON without cookies or credential headers, or nil when there was nothing to remove.
    public static func scrubbed(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        var removedAnything = false
        let cleaned = scrub(object, removedAnything: &removedAnything, inHeaders: false)
        guard removedAnything else { return nil }
        return try? JSONSerialization.data(withJSONObject: cleaned, options: [.fragmentsAllowed])
    }

    private static func scrub(_ value: Any, removedAnything: inout Bool, inHeaders: Bool) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                let lowered = key.lowercased()
                if (!inHeaders && key == "cookies") || (inHeaders && sensitiveHeaders.contains(lowered)) {
                    removedAnything = true
                    continue
                }
                result[key] = scrub(child, removedAnything: &removedAnything, inHeaders: key == "http_headers")
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { scrub($0, removedAnything: &removedAnything, inHeaders: false) }
        }
        return value
    }
}
