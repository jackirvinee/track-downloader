from __future__ import annotations

import argparse
import dataclasses
import shlex
import shutil
import subprocess
import time
import sys
import tempfile
from pathlib import Path

from track_downloader import __version__
from track_downloader.cdj_safe import make_cdj_safe
from track_downloader.credential_scrub import scrub_info_json_files
from track_downloader.url_validation import normalize_url
from track_downloader.ytdlp_args import DownloadOptions, SUPPORTED_AUDIO_FORMATS, build_ytdlp_command


DEFAULT_OUTPUT_DIR = Path("~/Downloads/Track Downloader")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="track-downloader",
        description="Download the best available YouTube/SoundCloud audio with DJ-library metadata.",
    )
    parser.add_argument("urls", nargs="+", help="YouTube, YouTube Music, or SoundCloud URL(s).")
    parser.add_argument(
        "-o",
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help="Destination folder. Default: ~/Downloads/Track Downloader",
    )
    parser.add_argument(
        "--audio-format",
        choices=sorted(SUPPORTED_AUDIO_FORMATS),
        default="best",
        help="Output format. Use 'best' to preserve source quality; use m4a/mp3 only for compatibility.",
    )
    parser.add_argument(
        "--playlist",
        action="store_true",
        help="Allow playlist downloads. By default, a playlist URL downloads only the current track.",
    )
    parser.add_argument(
        "--cookies-from-browser",
        metavar="BROWSER",
        help="Ask yt-dlp to use browser cookies, e.g. chrome, safari, firefox. Use only for accounts you control.",
    )
    parser.add_argument(
        "--no-archive",
        action="store_true",
        help="Do not write/use the per-library download archive.",
    )
    parser.add_argument(
        "--no-cdj-safe",
        dest="cdj_safe",
        action="store_false",
        help=(
            "Keep files exactly as yt-dlp saved them. By default, anything some Pioneer CDJ/XDJ decks "
            "can't load (FLAC, ALAC, Opus, HE-AAC, 32-bit float, 88.2/96 kHz, a wrong extension) is "
            "rewritten as WAV or rewrapped so it plays on every deck."
        ),
    )
    parser.add_argument(
        "--yt-dlp-bin",
        default="yt-dlp",
        help="yt-dlp executable name or path. Default: yt-dlp",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the yt-dlp command without running it.",
    )
    parser.add_argument(
        "--extra-ytdlp-arg",
        action="append",
        default=[],
        metavar="ARG",
        help="Append one raw yt-dlp argument before URLs. Repeat for multiple args.",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        urls = [normalize_url(url) for url in args.urls]
    except ValueError as exc:
        parser.error(str(exc))

    output_dir = args.output_dir.expanduser()
    archive_file = output_dir / ".track-downloader-archive.txt"
    options = DownloadOptions(
        output_dir=output_dir,
        audio_format=args.audio_format,
        playlist=args.playlist,
        cookies_from_browser=args.cookies_from_browser,
        use_archive=not args.no_archive,
        archive_file=archive_file,
        yt_dlp_bin=args.yt_dlp_bin,
        extra_ytdlp_args=args.extra_ytdlp_arg,
    )
    command = build_ytdlp_command(urls, options)

    if args.dry_run:
        print(shlex.join(command))
        return 0

    missing = _missing_runtime_tools(args.yt_dlp_bin)
    if missing:
        print(
            "Missing required tool(s): "
            + ", ".join(missing)
            + "\nInstall with: brew install yt-dlp ffmpeg",
            file=sys.stderr,
        )
        return 127

    output_dir.mkdir(parents=True, exist_ok=True)
    started_at = time.time()
    if not args.cdj_safe:
        returncode = subprocess.run(command, check=False).returncode
        scrub_info_json_files(output_dir, started_at)
        return returncode

    with tempfile.TemporaryDirectory(prefix="track-downloader-") as record_dir:
        saved_paths_file = Path(record_dir) / "saved-paths.txt"
        command = build_ytdlp_command(urls, dataclasses.replace(options, saved_paths_file=saved_paths_file))
        returncode = subprocess.run(command, check=False).returncode
        scrub_info_json_files(output_dir, started_at)
        saved = saved_paths_file.read_text(encoding="utf-8").splitlines() if saved_paths_file.exists() else []
    for line in dict.fromkeys(line for line in saved if line):
        outcome = make_cdj_safe(Path(line), output_dir)
        stream = sys.stderr if outcome.status == "left_as_downloaded" else sys.stdout
        print(f"[cdj-safe] {outcome.path.name}: {outcome.summary}", file=stream)
    return returncode


def _missing_runtime_tools(yt_dlp_bin: str) -> list[str]:
    required = [(yt_dlp_bin, "yt-dlp"), ("ffmpeg", "ffmpeg"), ("ffprobe", "ffprobe")]
    return [label for executable, label in required if shutil.which(executable) is None]
