from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path


SUPPORTED_AUDIO_FORMATS = {"best", "m4a", "mp3", "opus", "flac", "wav", "aac", "alac", "vorbis"}
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
        "--format",
        "bestaudio/best",
        "--format-sort",
        "acodec,abr,asr",
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

    command.extend(options.extra_ytdlp_args)
    command.extend(urls)
    return command
