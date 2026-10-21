import Foundation

public enum DownloadCommandBuilder {
    public static let outputTemplate =
        "%(extractor_key)s/%(uploader|Unknown Artist)s - %(title).180B [%(id)s].%(ext)s"

    public static func arguments(
        sourceURL: URL,
        outputDirectory: URL,
        cookiesBrowser: String? = nil,
        ffmpegPath: String? = nil,
        denoPath: String? = nil
    ) -> [String] {
        var arguments = [
            "--js-runtimes", denoPath.map { "deno:\($0)" } ?? "deno",
            "--remote-components", "ejs:github"
        ]
        + YTDLPAudioSelectionPolicy.arguments
        + [
            "--extract-audio",
            "--audio-format", "best",
            "--embed-metadata",
            "--embed-thumbnail",
            "--convert-thumbnails", "jpg",
            "--write-info-json",
            "--no-clean-infojson",
            "--newline",
            "--progress",
            "--progress-delta", "0.5",
            "--progress-template",
            "download:track-downloader:progress:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--progress-template",
            "postprocess:track-downloader:postprocess:%(progress.postprocessor)s",
            "--continue",
            "--no-overwrites",
            "--retries", "10",
            "--fragment-retries", "10",
            "--sleep-requests", "1",
            "--paths", outputDirectory.path,
            "--output", outputTemplate,
            "--download-archive", outputDirectory
                .appendingPathComponent(".track-downloader-archive.txt")
                .path,
            "--no-playlist",
            "--print", "after_move:track-downloader:filepath:%(filepath)s",
            // --print implies quiet mode, which hides archive-skip evidence.
            "--no-quiet"
        ]

        if let ffmpegPath, !ffmpegPath.isEmpty {
            arguments.append(contentsOf: ["--ffmpeg-location", ffmpegPath])
        }

        if let cookiesBrowser, !cookiesBrowser.isEmpty {
            arguments.append(contentsOf: ["--cookies-from-browser", cookiesBrowser])
        }

        arguments.append(sourceURL.absoluteString)
        return arguments
    }
}
