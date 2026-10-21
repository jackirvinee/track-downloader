using System.Diagnostics;

namespace TrackDownloader.Windows.Core;

public static class DownloadProcess
{
    public static ProcessStartInfo CreateStartInfo(
        ToolPaths tools,
        Uri url,
        string outputDirectory,
        string inheritedPath)
    {
        ArgumentNullException.ThrowIfNull(tools);
        var ffmpegDirectory = Path.GetDirectoryName(tools.Ffmpeg)
            ?? throw new ArgumentException("FFmpeg must have a parent directory.", nameof(tools));
        var denoDirectory = Path.GetDirectoryName(tools.Deno)
            ?? throw new ArgumentException("Deno must have a parent directory.", nameof(tools));
        var startInfo = new ProcessStartInfo(tools.YtDlp)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        startInfo.Environment["PATH"] = string.IsNullOrWhiteSpace(inheritedPath)
            ? denoDirectory
            : string.Join(Path.PathSeparator, denoDirectory, inheritedPath);

        startInfo.ArgumentList.Add("--ffmpeg-location");
        startInfo.ArgumentList.Add(ffmpegDirectory);
        foreach (var argument in YtDlpArguments.Create(url, outputDirectory))
        {
            startInfo.ArgumentList.Add(argument);
        }

        return startInfo;
    }
}
