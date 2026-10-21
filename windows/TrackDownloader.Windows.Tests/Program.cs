using TrackDownloader.Windows.Core;

var tests = new (string Name, Action Run)[]
{
    ("accepts supported HTTPS URLs", () =>
    {
        AssertEqual("https", UrlPolicy.Validate("https://www.youtube.com/watch?v=abc").Scheme);
        AssertEqual("soundcloud.com", UrlPolicy.Validate("https://soundcloud.com/artist/track").Host);
    }),
    ("rejects non-HTTPS and unsupported hosts", () =>
    {
        AssertThrows(() => UrlPolicy.Validate("http://youtube.com/watch?v=abc"));
        AssertThrows(() => UrlPolicy.Validate("https://youtube.example/watch?v=abc"));
        AssertThrows(() => UrlPolicy.Validate("file:///tmp/audio"));
    }),
    ("prefers app-adjacent runtime tools", () =>
    {
        using var directory = new TestDirectory();
        var applicationDirectory = directory.Create("app");
        var pathDirectory = directory.Create("path");
        foreach (var name in ToolLocator.RequiredToolNames)
        {
            File.WriteAllText(Path.Combine(applicationDirectory, name), "app");
            File.WriteAllText(Path.Combine(pathDirectory, name), "path");
        }

        var tools = ToolLocator.FindRequired(applicationDirectory, pathDirectory);

        AssertEqual(Path.Combine(applicationDirectory, "yt-dlp.exe"), tools.YtDlp);
        AssertEqual(Path.Combine(applicationDirectory, "ffmpeg.exe"), tools.Ffmpeg);
        AssertEqual(Path.Combine(applicationDirectory, "ffprobe.exe"), tools.Ffprobe);
        AssertEqual(Path.Combine(applicationDirectory, "deno.exe"), tools.Deno);
    }),
    ("finds Deno on PATH when it is not beside the app", () =>
    {
        using var directory = new TestDirectory();
        var applicationDirectory = directory.Create("app");
        var pathDirectory = directory.Create("path");
        foreach (var name in new[] { "yt-dlp.exe", "ffmpeg.exe", "ffprobe.exe" })
        {
            File.WriteAllText(Path.Combine(applicationDirectory, name), "app");
        }
        File.WriteAllText(Path.Combine(pathDirectory, "deno.exe"), "path");

        var tools = ToolLocator.FindRequired(applicationDirectory, pathDirectory);

        AssertEqual(Path.Combine(pathDirectory, "deno.exe"), tools.Deno);
    }),
    ("reports the fixed dependency guidance when Deno is missing", () =>
    {
        using var directory = new TestDirectory();
        var applicationDirectory = directory.Create("app");
        foreach (var name in new[] { "yt-dlp.exe", "ffmpeg.exe", "ffprobe.exe" })
        {
            File.WriteAllText(Path.Combine(applicationDirectory, name), "app");
        }

        try
        {
            ToolLocator.FindRequired(applicationDirectory, string.Empty);
            throw new InvalidOperationException("Expected missing Deno to fail dependency resolution.");
        }
        catch (ToolResolutionException error)
        {
            AssertEqual("deno.exe", error.MissingTools.Single());
            AssertEqual(
                "Install or place yt-dlp.exe, ffmpeg.exe, ffprobe.exe, and deno.exe beside the app or on PATH.",
                error.Message);
        }
    }),
    ("builds a direct yt-dlp argument list", () =>
    {
        var arguments = YtDlpArguments.Create(
            new Uri("https://soundcloud.com/artist/track"),
            "C:\\TestOutput\\Track Downloader");

        AssertEqual("--js-runtimes", arguments[0]);
        AssertEqual("deno", arguments[1]);
        AssertEqual("--remote-components", arguments[2]);
        AssertEqual("ejs:github", arguments[3]);
        AssertEqual("--format", arguments[4]);
        AssertEqual("bestaudio/best", arguments[5]);
        AssertEqual("deno", ValueAfter("--js-runtimes", arguments));
        AssertEqual("ejs:github", ValueAfter("--remote-components", arguments));
        AssertEqual("--no-playlist", arguments[^2]);
        AssertEqual("https://soundcloud.com/artist/track", arguments[^1]);
        AssertFalse(arguments.Any(argument => argument.Contains("cmd.exe", StringComparison.OrdinalIgnoreCase)));
        AssertFalse(arguments.Any(argument => argument.Contains("powershell", StringComparison.OrdinalIgnoreCase)));
    }),
    ("creates a downloader process without a shell", () =>
    {
        using var directory = new TestDirectory();
        var denoDirectory = directory.Create("deno");
        var inheritedPath = directory.Create("inherited");
        var startInfo = DownloadProcess.CreateStartInfo(
            new ToolPaths(
                "C:\\tools\\yt-dlp.exe",
                "C:\\tools\\ffmpeg.exe",
                "C:\\tools\\ffprobe.exe",
                Path.Combine(denoDirectory, "deno.exe")),
            new Uri("https://www.youtube.com/watch?v=abc"),
            "C:\\TestOutput\\Track Downloader",
            inheritedPath);

        AssertEqual("C:\\tools\\yt-dlp.exe", startInfo.FileName);
        AssertFalse(startInfo.UseShellExecute);
        AssertTrue(startInfo.RedirectStandardOutput);
        AssertTrue(startInfo.RedirectStandardError);
        AssertTrue(startInfo.Environment["PATH"]!.StartsWith(denoDirectory + Path.PathSeparator, StringComparison.Ordinal));
        AssertTrue(startInfo.Environment["PATH"]!.EndsWith(inheritedPath, StringComparison.Ordinal));
        AssertEqual("https://www.youtube.com/watch?v=abc", startInfo.ArgumentList[^1]);
    }),
    ("parses only controlled progress records", () =>
    {
        AssertAlmostEqual(0.376, DownloadProgressParser.Parse("track-downloader:progress:37.6%").FractionCompleted ?? -1);
        AssertTrue(DownloadProgressParser.Parse("[download] 37.6% of 12MiB").FractionCompleted is null);
    }),
    ("opens an existing output folder through Explorer without a shell", () =>
    {
        using var directory = new TestDirectory();
        var outputDirectory = directory.Create("output");

        var startInfo = Explorer.CreateStartInfo(outputDirectory);

        AssertEqual("explorer.exe", startInfo.FileName);
        AssertFalse(startInfo.UseShellExecute);
        AssertEqual(Path.GetFullPath(outputDirectory), startInfo.ArgumentList.Single());
    }),
};

var failures = new List<string>();
foreach (var test in tests)
{
    try
    {
        test.Run();
        Console.WriteLine($"PASS {test.Name}");
    }
    catch (Exception error)
    {
        failures.Add($"FAIL {test.Name}: {error.Message}");
    }
}

if (failures.Count > 0)
{
    Console.Error.WriteLine(string.Join(Environment.NewLine, failures));
    return 1;
}

return 0;

static void AssertEqual(string expected, string actual)
{
    if (!string.Equals(expected, actual, StringComparison.Ordinal))
    {
        throw new InvalidOperationException($"Expected '{expected}' but received '{actual}'.");
    }
}

static void AssertThrows(Action action)
{
    try
    {
        action();
    }
    catch (ArgumentException)
    {
        return;
    }

    throw new InvalidOperationException("Expected ArgumentException.");
}

static void AssertFalse(bool value)
{
    if (value)
    {
        throw new InvalidOperationException("Expected false.");
    }
}

static void AssertTrue(bool value)
{
    if (!value)
    {
        throw new InvalidOperationException("Expected true.");
    }
}

static void AssertAlmostEqual(double expected, double actual)
{
    if (Math.Abs(expected - actual) > 0.000_001)
    {
        throw new InvalidOperationException($"Expected '{expected}' but received '{actual}'.");
    }
}

static string ValueAfter(string option, IReadOnlyList<string> arguments)
{
    var index = arguments.ToList().IndexOf(option);
    if (index < 0 || index + 1 >= arguments.Count)
    {
        throw new InvalidOperationException($"Expected argument '{option}' with a value.");
    }

    return arguments[index + 1];
}

sealed class TestDirectory : IDisposable
{
    private readonly string path = Path.Combine(Path.GetTempPath(), $"track-downloader-windows-tests-{Guid.NewGuid():N}");

    public string Create(string name)
    {
        var directory = Path.Combine(path, name);
        Directory.CreateDirectory(directory);
        return directory;
    }

    public void Dispose()
    {
        if (Directory.Exists(path))
        {
            Directory.Delete(path, recursive: true);
        }
    }
}
