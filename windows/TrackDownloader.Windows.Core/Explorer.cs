using System.Diagnostics;

namespace TrackDownloader.Windows.Core;

public static class Explorer
{
    public static ProcessStartInfo CreateStartInfo(string directory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(directory);
        var fullPath = Path.GetFullPath(directory);
        if (!Directory.Exists(fullPath))
        {
            throw new DirectoryNotFoundException("The Track Downloader output folder is unavailable.");
        }

        var startInfo = new ProcessStartInfo("explorer.exe")
        {
            UseShellExecute = false,
        };
        startInfo.ArgumentList.Add(fullPath);
        return startInfo;
    }

    public static void Open(string directory)
    {
        using var process = Process.Start(CreateStartInfo(directory));
    }
}
