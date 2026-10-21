namespace TrackDownloader.Windows.Core;

public sealed record ToolPaths(string YtDlp, string Ffmpeg, string Ffprobe, string Deno);

public static class ToolLocator
{
    public static readonly string[] RequiredToolNames = ["yt-dlp.exe", "ffmpeg.exe", "ffprobe.exe", "deno.exe"];

    public static ToolPaths FindRequired(string applicationDirectory, string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(applicationDirectory);

        var directories = new[] { applicationDirectory }
            .Concat(path.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
        var locations = RequiredToolNames.ToDictionary(
            name => name,
            name => directories.Select(directory => Path.Combine(directory, name)).FirstOrDefault(File.Exists),
            StringComparer.OrdinalIgnoreCase);
        var missing = locations.Where(entry => entry.Value is null).Select(entry => entry.Key).ToArray();

        if (missing.Length > 0)
        {
            throw new ToolResolutionException(missing);
        }

        return new ToolPaths(
            locations["yt-dlp.exe"]!,
            locations["ffmpeg.exe"]!,
            locations["ffprobe.exe"]!,
            locations["deno.exe"]!);
    }
}

public sealed class ToolResolutionException(IReadOnlyList<string> missingTools) : Exception(
    "Install or place yt-dlp.exe, ffmpeg.exe, ffprobe.exe, and deno.exe beside the app or on PATH.")
{
    public IReadOnlyList<string> MissingTools { get; } = missingTools;
}
