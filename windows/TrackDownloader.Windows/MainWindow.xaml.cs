using System.Diagnostics;
using System.IO;
using System.Windows;
using TrackDownloader.Windows.Core;

namespace TrackDownloader.Windows;

public partial class MainWindow : Window
{
    private static readonly string OutputDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.MyMusic),
        "Track Downloader");
    private CancellationTokenSource? activeDownload;

    public MainWindow()
    {
        InitializeComponent();
        UrlBox.Focus();
    }

    private async void DownloadButton_Click(object sender, RoutedEventArgs eventArgs)
    {
        if (activeDownload is not null)
        {
            return;
        }

        Uri url;
        ToolPaths tools;
        var runtimePath = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        try
        {
            url = UrlPolicy.Validate(UrlBox.Text);
            Directory.CreateDirectory(OutputDirectory);
            tools = ToolLocator.FindRequired(AppContext.BaseDirectory, runtimePath);
        }
        catch (ArgumentException)
        {
            SetStatus("Paste a YouTube or SoundCloud HTTPS link.");
            return;
        }
        catch (ToolResolutionException error)
        {
            SetStatus(error.Message);
            return;
        }
        catch (IOException)
        {
            SetStatus("The Track Downloader output folder is unavailable.");
            return;
        }

        activeDownload = new CancellationTokenSource();
        SetRunning(true);
        try
        {
            var alreadyDownloaded = await RunDownloadAsync(
                DownloadProcess.CreateStartInfo(tools, url, OutputDirectory, runtimePath),
                activeDownload.Token);
            SetStatus(alreadyDownloaded
                ? "Previously downloaded. No new file was created; this link appears in Track Downloader's download history."
                : "Download finished. Use Show files to open the output folder.");
        }
        catch (OperationCanceledException)
        {
            SetStatus("Download cancelled.");
        }
        catch
        {
            SetStatus("Download could not finish. Confirm the required tools are available and try again.");
        }
        finally
        {
            activeDownload.Dispose();
            activeDownload = null;
            SetRunning(false);
        }
    }

    /// <returns>True when yt-dlp skipped the item because it was already downloaded.</returns>
    private async Task<bool> RunDownloadAsync(ProcessStartInfo startInfo, CancellationToken cancellationToken)
    {
        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("Unable to start the downloader.");
        using var cancellationRegistration = cancellationToken.Register(() =>
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        });

        var standardOutput = ReadProgressAsync(process.StandardOutput);
        var standardError = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        await Task.WhenAll(standardOutput, standardError);

        if (cancellationToken.IsCancellationRequested)
        {
            throw new OperationCanceledException(cancellationToken);
        }

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException("Downloader failed.");
        }

        return await standardOutput;
    }

    /// <returns>True when an archive or existing-file skip was reported.</returns>
    private async Task<bool> ReadProgressAsync(StreamReader reader)
    {
        var sawArchiveSkip = false;
        while (await reader.ReadLineAsync() is { } line)
        {
            sawArchiveSkip |= ArchiveSkipDetector.IsArchiveSkip(line);
            var progress = DownloadProgressParser.Parse(line).FractionCompleted;
            if (progress is not null)
            {
                await Dispatcher.InvokeAsync(() =>
                {
                    ProgressBar.Value = progress.Value * 100;
                    StatusText.Text = $"Downloading {progress.Value:P0}";
                });
            }
        }

        return sawArchiveSkip;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs eventArgs)
    {
        activeDownload?.Cancel();
    }

    protected override void OnClosed(EventArgs e)
    {
        // Closing the window ends the app; stop yt-dlp and its ffmpeg children
        // instead of leaving them running invisibly.
        try
        {
            activeDownload?.Cancel();
        }
        catch (AggregateException)
        {
            // The process may already be exiting; closing must not fail.
        }

        base.OnClosed(e);
    }

    private void ShowFilesButton_Click(object sender, RoutedEventArgs eventArgs)
    {
        try
        {
            Directory.CreateDirectory(OutputDirectory);
            Explorer.Open(OutputDirectory);
        }
        catch
        {
            SetStatus("The Track Downloader output folder is unavailable.");
        }
    }

    private void SetRunning(bool running)
    {
        DownloadButton.IsEnabled = !running;
        CancelButton.IsEnabled = running;
        UrlBox.IsEnabled = !running;
        ProgressBar.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        if (!running)
        {
            ProgressBar.Value = 0;
        }
    }

    private void SetStatus(string value)
    {
        StatusText.Text = value;
    }
}
