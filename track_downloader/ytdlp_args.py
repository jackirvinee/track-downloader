from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path


SUPPORTED_AUDIO_FORMATS = {"best", "m4a", "mp3", "opus", "flac", "wav", "aac", "alac", "vorbis"}
# Mirrors YTDLPAudioSelectionPolicy.swift. The uploader's original ("download") always wins;
# then the extractor's quality tier (SoundCloud Go+/160k AAC, YouTube non-DRC); then bitrate
# before codec, so a 128 kbps MP3 beats a 96 kbps AAC.
AUDIO_SELECTION_ARGS = ("--format", "download/bestaudio/best", "--format-sort", "quality,abr,acodec,asr")
# Mirrors DownloadCommandBuilder.originalExtensionArguments. An uploader's original keeps the
# extension of their file name; unless it's a lower-case one yt-dlp knows, --audio-format best
# re-encodes PCM (.aif, .WAV) to a low-bitrate MP3 or, for .MP3/.M4A/.FLAC, overwrites the file
# with itself on a case-insensitive disk. Normalising the extension first keeps the original intact.
ORIGINAL_EXTENSION_ARGS = tuple(
    arg
    for pattern, replacement in (
        ("(?i)^aif[cf]?$", "aiff"),
        ("(?i)^(wave?|bwf)$", "wav"),
        ("(?i)^mp3$", "mp3"),
        ("(?i)^m4a$", "m4a"),
        ("(?i)^flac$", "flac"),
        ("(?i)^ogg$", "ogg"),
        ("(?i)^opus$", "opus"),
    )
    for arg in ("--replace-in-metadata", "video:ext", pattern, replacement)
)
DEFAULT_OUTPUT_TEMPLATE = "%(extractor_key)s/%(uploader|Unknown Artist)s - %(title).180B [%(id)s].%(ext)s"


@dataclass(frozen=True)
class DownloadOptions:
    output_dir: Path
    audio_format: str = "best"
    playlist: bool = False
    cookies_from_browser: str | None = None
    use_archive: bool = True
    archive_file: Path | None = None
    yt_dlp_bin: str = "yt-dlp"
    extra_ytdlp_args: list[str] = field(default_factory=list)
    # yt-dlp appends the final path of every saved file here, for the post-download CDJ-safe step.
    saved_paths_file: Path | None = None


def build_ytdlp_command(urls: list[str], options: DownloadOptions) -> list[str]:
    if not urls:
        raise ValueError("at least one URL is required")

    audio_format = options.audio_format.lower()
    if audio_format not in SUPPORTED_AUDIO_FORMATS:
        supported = ", ".join(sorted(SUPPORTED_AUDIO_FORMATS))
        raise ValueError(f"unsupported audio format {options.audio_format!r}; expected one of: {supported}")

    output_dir = options.output_dir.expanduser()
    command = [
        options.yt_dlp_bin,
        *AUDIO_SELECTION_ARGS,
        *ORIGINAL_EXTENSION_ARGS,
        "--extract-audio",
        "--audio-format",
        audio_format,
        "--embed-metadata",
        "--embed-thumbnail",
        "--convert-thumbnails",
        "jpg",
        "--write-info-json",
        "--no-clean-infojson",
        "--newline",
        "--continue",
        "--no-overwrites",
        "--retries",
        "10",
        "--fragment-retries",
        "10",
        "--sleep-requests",
        "1",
        "--paths",
        str(output_dir),
        "--output",
        DEFAULT_OUTPUT_TEMPLATE,
    ]

    if options.use_archive:
        archive_file = options.archive_file
        if archive_file is None:
            archive_file = output_dir / ".track-downloader-archive.txt"
        command.extend(["--download-archive", str(archive_file.expanduser())])

    if audio_format == "mp3":
        command.extend(["--audio-quality", "0"])

    if not options.playlist:
        command.append("--no-playlist")

    if options.cookies_from_browser:
        command.extend(["--cookies-from-browser", options.cookies_from_browser])

    if options.saved_paths_file is not None:
        # The file name is itself an output template, so a literal % must be doubled.
        record = str(options.saved_paths_file).replace("%", "%%")
        command.extend(["--print-to-file", "after_move:%(filepath)s", record])

    command.extend(options.extra_ytdlp_args)
    command.extend(urls)
    return command
