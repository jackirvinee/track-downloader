import Foundation

public enum SourcePreflightCommandBuilder {
    public static func arguments(sourceURL: URL, denoPath: String? = nil) -> [String] {
        [
            "--js-runtimes", denoPath.map { "deno:\($0)" } ?? "deno",
            "--remote-components", "ejs:github"
        ]
        + YTDLPAudioSelectionPolicy.arguments
        + [
            "--dump-single-json",
            "--simulate",
            "--no-playlist",
            "--no-warnings",
            sourceURL.absoluteString
        ]
    }
}
