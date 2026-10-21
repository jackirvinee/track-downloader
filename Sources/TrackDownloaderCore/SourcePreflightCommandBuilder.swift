import Foundation

public enum SourcePreflightCommandBuilder {
    public static func arguments(
        sourceURL: URL,
        cookiesBrowser: String? = nil,
        denoPath: String? = nil
    ) -> [String] {
        var arguments = [
            "--js-runtimes", denoPath.map { "deno:\($0)" } ?? "deno",
            "--remote-components", "ejs:github"
        ]
        + YTDLPAudioSelectionPolicy.arguments
        + [
            "--dump-single-json",
            "--simulate",
            "--no-playlist",
            "--no-warnings"
        ]
        if let cookiesBrowser, !cookiesBrowser.isEmpty {
            arguments.append(contentsOf: ["--cookies-from-browser", cookiesBrowser])
        }
        arguments.append(sourceURL.absoluteString)
        return arguments
    }
}
