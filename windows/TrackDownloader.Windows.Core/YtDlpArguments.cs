namespace TrackDownloader.Windows.Core;

public static class YtDlpArguments
{
    private const string OutputTemplate = "%(extractor_key)s/%(uploader|Unknown Artist)s - %(title).180B [%(id)s].%(ext)s";

    public static IReadOnlyList<string> Create(Uri url, string outputDirectory)
    {
        ArgumentNullException.ThrowIfNull(url);
        ArgumentException.ThrowIfNullOrWhiteSpace(outputDirectory);

        return
        [
            "--js-runtimes", "deno",
            "--remote-components", "ejs:github",
            "--format", "bestaudio/best",
            "--format-sort", "acodec,abr,asr",
            "--extract-audio",
            "--audio-format", "best",
            "--embed-metadata",
            "--embed-thumbnail",
            "--convert-thumbnails", "jpg",
            "--write-info-json",
            "--no-clean-infojson",
            "--newline",
            "--progress-template", "download:track-downloader:progress:%(progress._percent_str)s",
            "--continue",
            "--no-overwrites",
            "--retries", "10",
            "--fragment-retries", "10",
            "--sleep-requests", "1",
            "--paths", outputDirectory,
            "--output", OutputTemplate,
            "--download-archive", Path.Combine(outputDirectory, ".track-downloader-archive.txt"),
            "--no-playlist",
            url.AbsoluteUri,
        ];
    }
}
