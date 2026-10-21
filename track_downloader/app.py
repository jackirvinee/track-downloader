from __future__ import annotations

import subprocess
import time
import os
import re
import stat
from pathlib import Path

from track_downloader.cli import DEFAULT_OUTPUT_DIR, _missing_runtime_tools
from track_downloader.quality import AUDIO_EXTENSIONS, find_newest_audio_file, inspect_audio_quality
from track_downloader.search import open_higher_quality_searches, search_terms_from_audio_path
from track_downloader.url_validation import normalize_url
from track_downloader.ytdlp_args import DownloadOptions, build_ytdlp_command


_URL_IN_TRANSCRIPT = re.compile(r"https?://[^\s<>'\"]+", re.IGNORECASE)
_SENSITIVE_TRANSCRIPT_VALUE = re.compile(
    r"\b(authorization|cookie|x-api-key|api[_-]?key|access[_-]?token|oauth[_-]?token|token|secret|password)"
    r"\s*([=:])\s*(?:bearer\s+)?[^\s,;]+",
    re.IGNORECASE,
)


def redact_transcript_line(line: str) -> str:
    without_urls = _URL_IN_TRANSCRIPT.sub("<redacted-url>", line)
    return _SENSITIVE_TRANSCRIPT_VALUE.sub(r"\1\2 <redacted-secret>", without_urls)


def open_contained_output_root(output_dir: Path) -> tuple[int, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    output_root = output_dir.resolve(strict=True)
    if not output_root.is_dir():
        raise OSError(f"Output root is not a directory: {output_dir}")

    no_follow = getattr(os, "O_NOFOLLOW", None)
    directory_only = getattr(os, "O_DIRECTORY", None)
    if no_follow is None or directory_only is None:
        raise OSError("Safe output-root file writes are unavailable on this platform.")

    directory_fd = os.open(output_root, os.O_RDONLY | directory_only | no_follow)
    try:
        opened_root = os.fstat(directory_fd)
        named_root = os.stat(output_root, follow_symlinks=False)
        if not stat.S_ISDIR(opened_root.st_mode) or (
            opened_root.st_dev,
            opened_root.st_ino,
        ) != (
            named_root.st_dev,
            named_root.st_ino,
        ):
            raise OSError(f"Output root changed while opening: {output_dir}")
        return directory_fd, output_root
    except BaseException:
        os.close(directory_fd)
        raise


def open_contained_append_file(output_dir: Path, filename: str):
    if not filename or Path(filename).name != filename or filename in {".", ".."}:
        raise ValueError("Output filename must be a single basename.")

    no_follow = getattr(os, "O_NOFOLLOW", None)
    if no_follow is None:
        raise OSError("Safe output-root file writes are unavailable on this platform.")

    directory_fd, output_root = open_contained_output_root(output_dir)
    target = output_root / filename
    try:
        file_fd = os.open(
            filename,
            os.O_WRONLY | os.O_APPEND | os.O_CREAT | no_follow,
            0o600,
            dir_fd=directory_fd,
        )
    finally:
        os.close(directory_fd)

    try:
        if not stat.S_ISREG(os.fstat(file_fd).st_mode):
            raise OSError(f"Refusing to write a non-regular file: {target}")
        return os.fdopen(file_fd, "a", encoding="utf-8", errors="replace")
    except BaseException:
        os.close(file_fd)
        raise


def open_contained_regular_file(output_dir: Path, path: Path):
    no_follow = getattr(os, "O_NOFOLLOW", None)
    directory_only = getattr(os, "O_DIRECTORY", None)
    if no_follow is None or directory_only is None:
        raise OSError("Safe output-root file reads are unavailable on this platform.")

    root_descriptor, output_root = open_contained_output_root(output_dir)
    opened_parent_descriptors: list[int] = []
    file_descriptor: int | None = None
    try:
        resolved_path = path.resolve(strict=True)
        try:
            components = resolved_path.relative_to(output_root).parts
        except ValueError as exc:
            raise OSError(f"Refusing to inspect a file outside the output root: {path}") from exc
        if not components:
            raise OSError(f"Refusing to inspect the output root as a file: {path}")

        parent_descriptor = root_descriptor
        for component in components[:-1]:
            descriptor = os.open(
                component,
                os.O_RDONLY | directory_only | no_follow,
                dir_fd=parent_descriptor,
            )
            opened_parent_descriptors.append(descriptor)
            parent_descriptor = descriptor

        file_descriptor = os.open(
            components[-1],
            os.O_RDONLY | no_follow,
            dir_fd=parent_descriptor,
        )
        opened_file = os.fstat(file_descriptor)
        named_file = os.stat(components[-1], dir_fd=parent_descriptor, follow_symlinks=False)
        if not stat.S_ISREG(opened_file.st_mode) or (
            opened_file.st_dev,
            opened_file.st_ino,
        ) != (
            named_file.st_dev,
            named_file.st_ino,
        ):
            raise OSError(f"Refusing to inspect a file that changed while opening: {path}")
        return os.fdopen(file_descriptor, "rb")
    except BaseException:
        if file_descriptor is not None:
            os.close(file_descriptor)
        raise
    finally:
        for descriptor in reversed(opened_parent_descriptors):
            os.close(descriptor)
        os.close(root_descriptor)


def build_gui_download_command(url: str) -> list[str]:
    normalized_url = normalize_url(url)
    output_dir = DEFAULT_OUTPUT_DIR.expanduser()
    cookies_browser = os.environ.get("TRACK_DOWNLOADER_COOKIES_BROWSER", "").strip() or None
    return build_ytdlp_command(
        [normalized_url],
        DownloadOptions(
            output_dir=output_dir,
            archive_file=output_dir / ".track-downloader-archive.txt",
            cookies_from_browser=cookies_browser,
            extra_ytdlp_args=["--no-progress", "--print", "after_move:filepath"],
        ),
    )


def resolve_downloaded_audio_file(output_lines: list[str], output_dir: Path, since: float) -> Path | None:
    output_root = output_dir.resolve()
    for line in reversed(output_lines):
        candidate = Path(line.strip())
        if not line.strip() or candidate.suffix.lower() not in AUDIO_EXTENSIONS:
            continue

        if not candidate.is_absolute():
            candidate = output_dir / candidate

        try:
            resolved_candidate = candidate.resolve()
        except (OSError, RuntimeError):
            continue

        if resolved_candidate.is_relative_to(output_root) and resolved_candidate.is_file():
            return candidate

    return find_newest_audio_file(output_dir, since=since)


def quote_applescript_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def parse_dialog_text_result(output: str) -> str:
    marker = "text returned:"
    if marker not in output:
        return ""
    return output.split(marker, 1)[1].strip()


def run_osascript(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
        errors="replace",
        check=False,
    )


def prompt_for_url() -> str | None:
    script = (
        'display dialog "Paste a YouTube or SoundCloud link" '
        'default answer "" buttons {"Cancel", "Download"} '
        'default button "Download" cancel button "Cancel" '
        'with title "Track Downloader"'
    )
    result = run_osascript(script)
    if result.returncode != 0:
        return None
    return parse_dialog_text_result(result.stdout)


def show_alert(title: str, message: str, style: str = "informational") -> None:
    script = (
        f"display alert {quote_applescript_string(title)} "
        f"message {quote_applescript_string(message)} "
        f"as {style}"
    )
    run_osascript(script)


def ask_yes_no(title: str, message: str) -> bool:
    script = (
        f"display dialog {quote_applescript_string(message)} "
        'buttons {"No", "Yes"} default button "Yes" cancel button "No" '
        f"with title {quote_applescript_string(title)}"
    )
    result = run_osascript(script)
    return result.returncode == 0 and "button returned:Yes" in result.stdout


def append_quality_report(output_dir: Path, message: str) -> None:
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with open_contained_append_file(output_dir, "track-downloader-quality-report.txt") as report:
        report.write(f"[{timestamp}] {message}\n\n")


def summarize_failed_download(output_lines: list[str], log_path: Path) -> str:
    important = [
        line.strip()
        for line in output_lines
        if line.strip().startswith("ERROR:")
    ]
    if not important:
        important = [
            line.strip()
            for line in output_lines
            if "Unable to" in line or "HTTP Error" in line or "Unsupported URL" in line
        ]
    detail = redact_transcript_line(important[-1]) if important else "yt-dlp exited without a detailed error message."
    return f"Download failed.\n{detail}\n\nLog: {log_path}"


def main() -> int:
    pasted_url = prompt_for_url()
    if pasted_url is None:
        return 0

    try:
        command = build_gui_download_command(pasted_url)
    except ValueError as exc:
        show_alert("Track Downloader", str(exc), style="critical")
        return 2

    missing = _missing_runtime_tools("yt-dlp")
    if missing:
        show_alert("Track Downloader", "Missing required tool(s): " + ", ".join(missing), style="critical")
        return 127

    output_dir = DEFAULT_OUTPUT_DIR.expanduser()
    message, audio_file, offer_search, is_error = run_download(command, output_dir)
    try:
        append_quality_report(output_dir, message.replace("\n", " | "))
    except OSError as exc:
        show_alert("Track Downloader error", f"{message}\n\nQuality report was not written safely: {exc}", style="critical")
        return 1
    show_alert("Track Downloader quality report" if not is_error else "Track Downloader error", message, style="warning" if offer_search else "informational")

    if offer_search and audio_file is not None and ask_yes_no(
        "Find a better source?",
        "Open searches for a higher-quality version from legitimate sources?",
    ):
        open_higher_quality_searches(search_terms_from_audio_path(audio_file))

    return 1 if is_error else 0


def run_download(command: list[str], output_dir: Path) -> tuple[str, Path | None, bool, bool]:
    log_path = output_dir / "track-downloader-last-download.log"
    start_time = time.time()
    output_lines: list[str] = []
    try:
        with open_contained_append_file(output_dir, "track-downloader-last-download.log") as log_file:
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                errors="replace",
                bufsize=1,
            )
            if process.stdout is not None:
                with process.stdout:
                    for line in process.stdout:
                        output_lines.append(line.rstrip("\n"))
                        log_file.write(redact_transcript_line(line))
            return_code = process.wait()
    except OSError as exc:
        return str(exc), None, False, True

    if return_code != 0:
        return summarize_failed_download(output_lines, log_path), None, False, True

    audio_file = resolve_downloaded_audio_file(output_lines, output_dir, since=start_time - 2)
    if audio_file is None:
        return (
            f"Download finished, but no new audio file was found. "
            f"It may already be in the archive. Check {output_dir}.",
            None,
            False,
            False,
        )

    try:
        with open_contained_regular_file(output_dir, audio_file) as standard_input:
            quality = inspect_audio_quality(audio_file, standard_input=standard_input)
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        return f"Downloaded {audio_file.name}, but quality inspection failed: {exc}", audio_file, False, False

    warning = ""
    if quality.kbps is not None and quality.kbps < 128:
        warning = "\n\nLow quality: probably not suitable for DJ use."
    elif quality.kbps is not None and quality.kbps < 160:
        warning = "\n\nBorderline quality: check before using in a set."

    offer_search = quality.verdict in {"low", "borderline", "unknown"}
    return (
        f"Downloaded: {audio_file.name}\nQuality: {quality.summary()}{warning}\n\nSaved in: {output_dir}",
        audio_file,
        offer_search,
        False,
    )


if __name__ == "__main__":
    raise SystemExit(main())
