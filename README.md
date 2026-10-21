# Track Downloader

The macOS app is a side-by-side Source and Library workbench: it checks source facts before enabling one explicit download, reports measured saved-file quality, and keeps local library organization non-destructive.

Track Downloader is a compact native macOS utility for saving audio from YouTube and SoundCloud links you are authorized to download. It wraps locally installed [`yt-dlp`](https://github.com/yt-dlp/yt-dlp), `ffmpeg`, `ffprobe`, and Deno; it checks a link before download, requests the best exposed audio only after your choice, preserves available metadata and artwork, and measures the file it actually saved.

> Use Track Downloader only for media you own, created, licensed, or otherwise have permission to download. It does not bypass DRM, paywalls, access controls, or platform restrictions. You are responsible for complying with the platforms' terms and applicable law.

## What it does

- Accepts supported YouTube, YouTube Music, and SoundCloud links in one focused window.
- Pasted links immediately clear the input and enter the persistent Track Queue for source checking; typed links enter it with Return. The input remains available during checks and downloads. Each ready row offers Download, and explicitly requested downloads run one at a time.
- Checks queued sources independently of adding more links. This may contact the source platform, but it does not download media during inspection; choose **Download** only after reviewing the source card.
- Runs one local download at a time with clear resolving, downloading, processing, and quality-inspection stages. A job can be cancelled, retried, or reset.
- Prefers an available uploader original, then the best exposed audio; embeds available metadata and artwork, scrubs cookie and authorization fields from `.info.json` sidecars, and maintains a per-output-folder archive to avoid duplicates.
- Does not read browser cookies by default. Settings offers an explicit SoundCloud browser/profile choice for an account you control. It is off by default and applies only to SoundCloud. The command-line flow also has an explicit browser-cookie option.
- Measures the saved file with `ffprobe` and reports its bitrate, codec, sample rate, and an honest quality verdict. Limited or unmeasurable results offer **Find Better Source**; they are never upscaled or represented as restored quality.
- Provides an inline local library with search, scopes, favourites, saved crates, configurable columns, preview, and Finder actions. Organization is non-destructive and never moves or edits audio files.
- Double-click a Library track to preview it with Quick Look. Preview does not hand the audio file to Apple Music or import it into a music library.
- Keeps downloads, the archive, and local logs on your Mac in `~/Downloads/Track Downloader`.

Track Downloader is not affiliated with YouTube, Google, SoundCloud, Homebrew, `yt-dlp`, or FFmpeg.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh/)
- `yt-dlp`, `ffmpeg`, and [Deno](https://deno.com/):

  ```bash
  brew install yt-dlp ffmpeg deno
  ```

Keep the extractors current when a platform changes:

```bash
brew upgrade yt-dlp ffmpeg deno
```

For current YouTube support, the app directs yt-dlp to run Deno and load the official `yt-dlp-ejs` challenge-solver package from the [`yt-dlp/ejs`](https://github.com/yt-dlp/ejs) GitHub repository. yt-dlp caches that component locally; it may make a GitHub request when the component needs to be obtained or updated. Deno runs the solver with restricted permissions.

## Build and run

Clone the repository, then run:

```bash
./script/build_and_run.sh
```

The default mode builds an optimized release executable in a temporary staging directory, assembles and ad-hoc signs `Track Downloader.app`, verifies the signature, atomically installs it as `~/Applications/Track Downloader.app`, and opens that installed copy. Launch it later from Finder or Spotlight as you would any local app.

To build, strictly verify, and install the release bundle without opening a window:

```bash
./script/build_and_run.sh --bundle-check
```

`--verify` performs the same release staging and installation, opens the installed app, then confirms the `TrackDownloader` process is running. `--debug` stages a debug bundle only and opens its executable under LLDB. Build caches and the mutable signed bundle are deliberately staged under `TMPDIR`, not in the checkout.

Track Downloader is currently distributed as source under the MIT License. The checked-in `Track Downloader.app` is a source bundle template; the installed output is ad-hoc signed for local development and is not a notarized distribution for someone else.

## Windows preview

The repository also includes a compact, source-built Windows desktop preview. It accepts a supported HTTPS link, runs one local download at a time, shows controlled progress, supports cancellation, and opens its fixed output folder in Explorer. It uses the same conservative best-audio, metadata, thumbnail, sidecar, archive, retry, and no-playlist arguments as the native app.

The repository includes source for an MSIX packaging gate, but it is not a production binary release. The gate can create an unsigned, self-contained `win-x64` package in CI; installation still requires a trusted signature. It has no updater, bundled media tools, trusted release certificate, or completed clean-Windows-device proof. It does not read browser cookies, accept arbitrary yt-dlp arguments, or display raw downloader output.

On Windows 10 version 1809 or later, install the .NET 10 SDK and put `yt-dlp.exe`, `ffmpeg.exe`, `ffprobe.exe`, and `deno.exe` beside the built executable or on `PATH`. Then run:

```powershell
dotnet run --project windows/TrackDownloader.Windows/TrackDownloader.Windows.csproj
```

The Windows preview passes `--js-runtimes deno` and `--remote-components ejs:github` to yt-dlp, matching the native Mac app's challenge-solver behavior. yt-dlp may fetch and cache the official `yt-dlp-ejs` component from GitHub when it is missing or needs an update; Deno runs that solver through yt-dlp's restricted runtime integration.

Downloads are saved locally in `%USERPROFILE%\Music\Track Downloader`.

To build the unsigned MSIX source candidate on Windows with the .NET 10 SDK and Windows SDK packaging tools installed:

```powershell
.\script\build_windows_package.ps1 -Version 0.1.0.0
```

For a trusted release build, import the release code-signing certificate into the current user's certificate store and pass its thumbprint plus an HTTPS RFC 3161 timestamp service. The manifest publisher is taken from the certificate subject, and the script signs and verifies the package with SHA-256:

```powershell
.\script\build_windows_package.ps1 `
  -Version 0.1.0.0 `
  -SigningCertificateThumbprint "RELEASE_CERTIFICATE_SHA1_THUMBPRINT" `
  -TimestampUrl "https://timestamp.example.invalid"
```

Do not put a certificate, password, token, or real timestamp credential in the repository. After signing, run the clean-device gate on a separate Windows machine with the required media tools on `PATH` and a supported URL you are authorized to test:

```powershell
.\script\verify_windows_device.ps1 `
  -PackagePath ".\artifacts\windows\Track-Downloader-0.1.0.0-x64.msix" `
  -AuthorizedMediaUrl "https://www.youtube.com/watch?v=AUTHORIZED_TEST_ID"
```

That gate verifies the trusted package signature, probes the exact Deno/EJS yt-dlp flags against the authorized URL, installs the MSIX, and launches the app. A human must still confirm the native UI and one authorized app-driven download before device proof is complete.

## Google Chrome companion (local test)

The optional Chrome companion adds one explicit **Queue in Track Downloader** button beside the title on individual YouTube watch and SoundCloud track pages. It sends only the canonical page URL plus bounded title, creator, and platform text already visible on that page. It never reads cookies, history, downloads, or unrelated page contents, and it does not open or focus the Mac app.

Build and install the local app first, then register its native handoff:

```bash
./script/build_and_run.sh
./script/install_chrome_companion.sh
```

In Chrome, open `chrome://extensions`, turn on **Developer mode**, choose **Load unpacked**, and select this checkout’s `chrome-extension` folder. Open an individual YouTube watch or SoundCloud track page and choose **Queue in Track Downloader** beside its title. The page confirms whether the item was queued, was already waiting, or could not fit in the bounded 20-item queue.

Open Track Downloader when you are ready. Pending items remain beneath the Source form until you choose an individual **Download** or **Download All**. Each item is checked only after that choice; downloads run sequentially, successful items leave the queue, and unavailable or failed items stay marked for review. **Clear Queue** confirms before removing waiting items and never cancels an active download.

This is a local test companion only. It is not signed, published in the Chrome Web Store, or a substitute for the separate extension security review required before distribution.

## Updates

After a public stable release is available, Track Downloader checks for a newer version after launch and from **Settings → Updates → Check for Updates**. The app only opens the exact GitHub Release page for a validated newer version; it never downloads, installs, replaces, or deletes an app automatically.

To update manually, download the named `.zip` asset from that GitHub Release page, unzip it, drag the contained `Track Downloader.app` to Applications, and choose Finder's **Replace** when asked. Unsigned builds may require the normal macOS confirmation. Public release creation and binary distribution remain separate maintainer decisions.

## Using Track Downloader

Open the app and paste or type one supported link. After 400 ms, Track Downloader checks the source locally with `yt-dlp`; this can contact the source platform but does not download media. Browser cookies remain off unless you explicitly enable SoundCloud sign-in in Settings; that choice also applies to SoundCloud source inspection. Review the source card, then choose **Download** to start the existing local media workflow. Track Downloader has no service that receives your URLs, cookies, media, or quality reports.

Keep the transfer area on the current job and use the inline library below it to search, filter, preview, reveal, favourite, or group saved tracks into crates. Those library actions update local organization metadata only; they do not move, rename, or rewrite audio files.

Browser-cookie access is off by default. In Settings, choosing a SoundCloud browser/profile allows yt-dlp to read that session during SoundCloud inspection and download; other platforms do not use that native preference. Only the browser/profile preference is stored, and sidecar cookie and authorization fields are scrubbed after downloads, including failures. The command-line flow remains separate: if an authorized download genuinely requires an account session, its explicit option below can ask `yt-dlp` to read cookies from a browser profile you explicitly name. Track Downloader does not copy cookie values into its own files, but `yt-dlp` receives the selected session authority. Never share browser cookies, download logs, media URLs, or account data in an issue.

### CDJ-compatible output

On macOS and in Python, downloaded output is checked against common Pioneer CDJ/XDJ format constraints. Compatible files are retained; other formats may be remuxed or converted to WAV after validation. Lossy-to-WAV conversion does not restore audio detail. Quality is measured on the downloaded source before conversion. The Python CLI offers `--no-cdj-safe` to retain the source format. These source-tested rules do not establish physical deck compatibility; the Windows preview does not yet implement this step.

### Command line

The original command-line wrapper remains available:

```bash
track-downloader "https://soundcloud.com/artist/track"
track-downloader "https://www.youtube.com/watch?v=VIDEO_ID"
```

For a local command:

```bash
python3 -m pip install -e .
track-downloader --dry-run "https://www.youtube.com/watch?v=VIDEO_ID"
```

Useful options:

```bash
# Choose an output folder.
track-downloader -o "$HOME/Music/Rekordbox Import" "https://www.youtube.com/watch?v=VIDEO_ID"

# Request a compatible format only when your DJ workflow requires it.
track-downloader --audio-format m4a "https://www.youtube.com/watch?v=VIDEO_ID"

# Opt in to a playlist.
track-downloader --playlist "https://www.youtube.com/playlist?list=PLAYLIST_ID"

# Opt in to cookies from a browser profile you control.
track-downloader --cookies-from-browser chrome "https://www.youtube.com/watch?v=VIDEO_ID"
```

## Audio quality

The source card's bitrate is an extractor estimate for the selected source, not a saved-file measurement. The saved result is measured later with `ffprobe`. The best quality available is the best stream or original download that a platform makes available to your authorized account. Converting a lossy stream to WAV, AIFF, or FLAC makes a larger file; it does not restore lost detail. Track Downloader requests the best source format by default and reports what `ffprobe` finds in the saved file.

For DJ use, Track Downloader labels less than 128 kbps as limited, 128–159 kbps as borderline, 160–255 kbps as good, and 256 kbps or higher as excellent. These labels describe measured bitrate, not a guarantee of source fidelity. When quality is limited or unknown, look for an authorized original or store download instead of upconverting the stream.

## Development

Run the Swift tests:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/track-downloader-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/track-downloader-swiftpm-cache \
swift test --disable-sandbox
```

Run the Python tests:

```bash
python3 -m unittest
```

Run the Chrome companion contract tests:

```bash
node --test chrome-extension/tests/*.test.mjs
```

Run the Windows core checks:

```powershell
dotnet run --project windows/TrackDownloader.Windows.Tests/TrackDownloader.Windows.Tests.csproj
```

Build the Windows preview:

```powershell
dotnet build windows/TrackDownloader.Windows/TrackDownloader.Windows.csproj -c Release
```

Run a Python syntax check:

```bash
python3 -m py_compile track_downloader/*.py
```

Run the non-launching release bundle check (it installs to `~/Applications/Track Downloader.app`):

```bash
./script/build_and_run.sh --bundle-check
```

The test suite uses generated local fixtures. Do not add downloaded copyrighted media, cookies, API credentials, or personal download history to the repository.

## Contributing and security

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), [SECURITY.md](SECURITY.md), and the full [security model](SECURITY_MODEL.md) before opening an issue or pull request.

## License

Track Downloader is available under the [MIT License](LICENSE).
