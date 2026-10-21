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
                out var percent))
        {
            return new DownloadProgress(null);
        }

        return new DownloadProgress(Math.Clamp(percent, 0, 100) / 100);
    }
}
