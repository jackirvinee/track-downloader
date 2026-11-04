using System.Globalization;

namespace TrackDownloader.Windows.Core;

public sealed record DownloadProgress(double? FractionCompleted);

public static class DownloadProgressParser
{
    private const string Prefix = "track-downloader:progress:";

    public static DownloadProgress Parse(string line)
    {
        if (!line.StartsWith(Prefix, StringComparison.Ordinal) ||
            !double.TryParse(
                line[Prefix.Length..].Trim().TrimEnd('%'),
                NumberStyles.AllowDecimalPoint | NumberStyles.AllowLeadingSign,
                CultureInfo.InvariantCulture,
                out var percent) ||
            !double.IsFinite(percent))
        {
            return new DownloadProgress(null);
        }

        return new DownloadProgress(Math.Clamp(percent, 0, 100) / 100);
    }
}

/// Recognizes yt-dlp reporting that nothing new was saved because the item is
/// in the download archive or the file already exists. Mirrors the macOS app.
public static class ArchiveSkipDetector
{
    public static bool IsArchiveSkip(string line)
    {
        var normalized = line.Trim().ToLowerInvariant();
        return normalized.StartsWith("[download]", StringComparison.Ordinal)
            && !normalized.StartsWith("[download] destination:", StringComparison.Ordinal)
            && (normalized.EndsWith(" has already been recorded in the archive", StringComparison.Ordinal)
                || normalized.EndsWith(" has already been downloaded", StringComparison.Ordinal));
    }
}
