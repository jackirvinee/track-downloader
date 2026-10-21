namespace TrackDownloader.Windows.Core;

public static class UrlPolicy
{
    private static readonly string[] AllowedHosts =
    [
        "youtube.com",
        "youtu.be",
        "soundcloud.com",
    ];

    public static Uri Validate(string value)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            !Uri.TryCreate(value.Trim(), UriKind.Absolute, out var uri) ||
            uri.Scheme != Uri.UriSchemeHttps ||
            !IsAllowedHost(uri.Host))
        {
            throw new ArgumentException("Paste a YouTube or SoundCloud HTTPS link.", nameof(value));
        }

        return uri;
    }

    private static bool IsAllowedHost(string host)
    {
        return AllowedHosts.Any(allowed =>
            string.Equals(host, allowed, StringComparison.OrdinalIgnoreCase) ||
            host.EndsWith($".{allowed}", StringComparison.OrdinalIgnoreCase));
    }
}
