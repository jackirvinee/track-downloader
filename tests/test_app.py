import unittest
import tempfile
import sys
import os
from pathlib import Path
from unittest.mock import patch

from track_downloader.app import (
    build_gui_download_command,
    append_quality_report,
    normalize_url,
    open_contained_append_file,
    parse_dialog_text_result,
    quote_applescript_string,
    resolve_downloaded_audio_file,
    run_download,
    summarize_failed_download,
)
from track_downloader.quality import AudioQuality


class GuiAppTests(unittest.TestCase):
    def test_normalize_url_accepts_youtube_and_soundcloud_links(self):
        self.assertEqual(
            normalize_url("  https://www.youtube.com/watch?v=abc123  "),
            "https://www.youtube.com/watch?v=abc123",
        )
        self.assertEqual(
            normalize_url("https://soundcloud.com/artist/track"),
            "https://soundcloud.com/artist/track",
        )
        self.assertEqual(
            normalize_url("https://music.youtube.com/watch?v=abc123"),
            "https://music.youtube.com/watch?v=abc123",
        )

    def test_normalize_url_rejects_non_https_and_unsupported_hosts(self):
        for value in (
            "not a link",
            "http://soundcloud.com/artist/track",
            "https://example.com/track",
            "file:///tmp/audio.mp3",
        ):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    normalize_url(value)

    @patch.dict("os.environ", {}, clear=True)
    def test_gui_command_uses_default_output_folder_without_browser_cookies(self):
        command = build_gui_download_command("https://youtu.be/example")

        paths_index = command.index("--paths")
        print_index = command.index("--print")
        self.assertEqual(
            Path(command[paths_index + 1]),
            Path.home() / "Downloads" / "Track Downloader",
        )
        self.assertNotIn("--cookies-from-browser", command)
        self.assertIn("--no-progress", command)
        self.assertEqual(command[print_index + 1], "after_move:filepath")
        self.assertEqual(command[-1], "https://youtu.be/example")

    @patch.dict("os.environ", {"TRACK_DOWNLOADER_COOKIES_BROWSER": "chrome"}, clear=True)
    def test_gui_command_uses_browser_cookies_only_when_explicitly_configured(self):
        command = build_gui_download_command("https://youtu.be/example")

        cookies_index = command.index("--cookies-from-browser")
        self.assertEqual(command[cookies_index + 1], "chrome")

    def test_resolve_downloaded_audio_file_prefers_ytdlp_reported_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir)
            reported = output_dir / "SoundCloud" / "Artist - Track [id].opus"
            newer = output_dir / "Other" / "Newer File.m4a"
            reported.parent.mkdir()
            newer.parent.mkdir()
            reported.write_text("reported")
            newer.write_text("newer")

            resolved = resolve_downloaded_audio_file(
                [
                    "[download] Destination: temp",
                    str(reported),
                ],
                output_dir=output_dir,
                since=0,
            )

            self.assertEqual(resolved, reported)

    def test_resolve_downloaded_audio_file_falls_back_to_newest_audio_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir)
            audio = output_dir / "track.m4a"
            audio.write_text("audio")

            resolved = resolve_downloaded_audio_file(
                ["[download] no explicit path"],
                output_dir=output_dir,
                since=0,
            )

            self.assertEqual(resolved, audio)

    def test_resolve_downloaded_audio_file_ignores_reported_path_outside_output_root(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            workspace = Path(temp_dir)
            output_dir = workspace / "output"
            output_dir.mkdir()
            outside = workspace / "outside.opus"
            inside = output_dir / "inside.m4a"
            outside.write_text("outside")
            inside.write_text("inside")

            resolved = resolve_downloaded_audio_file(
                [str(outside)],
                output_dir=output_dir,
                since=0,
            )

            self.assertEqual(resolved, inside)

    def test_resolve_downloaded_audio_file_ignores_symlink_escape(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            workspace = Path(temp_dir)
            output_dir = workspace / "output"
            output_dir.mkdir()
            outside = workspace / "outside.opus"
            outside.write_text("outside")
            escaped = output_dir / "escaped.opus"
            escaped.symlink_to(outside)

            resolved = resolve_downloaded_audio_file(
                [str(escaped)],
                output_dir=output_dir,
                since=0,
            )

            self.assertIsNone(resolved)

    def test_parse_dialog_text_result_extracts_pasted_link(self):
        result = parse_dialog_text_result("button returned:Download, text returned:https://soundcloud.com/a/t")

        self.assertEqual(result, "https://soundcloud.com/a/t")

    def test_applescript_quote_escapes_dialog_text(self):
        quoted = quote_applescript_string('one "two" \\ three')

        self.assertEqual(quoted, '"one \\"two\\" \\\\ three"')

    def test_failed_download_summary_includes_last_ytdlp_error(self):
        message = summarize_failed_download(
            [
                "WARNING: old version",
                "ERROR: [soundcloud] Unable to download JSON metadata: HTTP Error 404: Not Found",
            ],
            Path("/tmp/track-downloader-last-download.log"),
        )

        self.assertIn("Unable to download JSON metadata", message)
        self.assertIn("/tmp/track-downloader-last-download.log", message)

    def test_run_download_redacts_private_urls_and_credentials_from_the_persisted_log(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir)
            secret = "s3cr3t-token"
            transcript = f"ERROR: fetch failed https://soundcloud.com/private?oauth_token={secret}"
            authorization = f"Authorization: Bearer {secret}"

            message, audio_file, offer_search, is_error = run_download(
                [sys.executable, "-c", f"print({transcript!r}); print({authorization!r})"], output_dir
            )

            log = (output_dir / "track-downloader-last-download.log").read_text(encoding="utf-8")
            self.assertFalse(is_error)
            self.assertIsNone(audio_file)
            self.assertFalse(offer_search)
            self.assertIn("Download finished", message)
            self.assertNotIn(secret, log)
            self.assertNotIn("soundcloud.com/private", log)
            self.assertIn("<redacted-url>", log)
            self.assertIn("Authorization: <redacted-secret>", log)

    def test_run_download_rejects_a_log_symlink_outside_the_output_root(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            workspace = Path(temp_dir)
            output_dir = workspace / "output"
            output_dir.mkdir()
            outside = workspace / "outside.log"
            outside.write_text("preserve me", encoding="utf-8")
            (output_dir / "track-downloader-last-download.log").symlink_to(outside)

            _, _, _, is_error = run_download([sys.executable, "-c", "print('safe')"], output_dir)

            self.assertTrue(is_error)
            self.assertEqual(outside.read_text(encoding="utf-8"), "preserve me")

    def test_run_download_keeps_quality_inspection_bound_to_the_opened_audio_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            workspace = Path(temp_dir)
            output_dir = workspace / "output"
            output_dir.mkdir()
            audio_file = output_dir / "track.opus"
            outside = workspace / "outside.opus"
            audio_file.write_bytes(b"inside-audio")
            outside.write_bytes(b"outside-audio")

            def inspect_opened_audio(path: Path, *, standard_input):
                audio_file.unlink()
                audio_file.symlink_to(outside)
                self.assertEqual(standard_input.read(), b"inside-audio")
                return AudioQuality(path=path, codec="opus", kbps=160, sample_rate_hz=48_000, verdict="good")

            with patch("track_downloader.app.inspect_audio_quality", side_effect=inspect_opened_audio):
                message, resolved_audio_file, offer_search, is_error = run_download(
                    [sys.executable, "-c", f"print({str(audio_file)!r})"], output_dir
                )

            self.assertFalse(is_error)
            self.assertEqual(resolved_audio_file, audio_file)
            self.assertFalse(offer_search)
            self.assertIn("Quality: 160 kbps opus", message)

    def test_failed_download_does_not_return_a_raw_private_url_from_the_transcript(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir)
            secret = "s3cr3t-token"
            transcript = f"ERROR: fetch failed https://soundcloud.com/private?oauth_token={secret}"

            message, _, _, is_error = run_download(
                [sys.executable, "-c", f"print({transcript!r}); raise SystemExit(1)"], output_dir
            )

            self.assertTrue(is_error)
            self.assertNotIn(secret, message)
            self.assertNotIn("soundcloud.com/private", message)
            self.assertIn("<redacted-url>", message)

    def test_append_quality_report_rejects_a_symlink_outside_the_output_root(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            workspace = Path(temp_dir)
            output_dir = workspace / "output"
            output_dir.mkdir()
            outside = workspace / "outside-report.txt"
            outside.write_text("preserve me", encoding="utf-8")
            (output_dir / "track-downloader-quality-report.txt").symlink_to(outside)

            with self.assertRaises(OSError):
                append_quality_report(output_dir, "Quality: good")

            self.assertEqual(outside.read_text(encoding="utf-8"), "preserve me")

    def test_append_quality_report_appends_to_a_regular_file_in_the_output_root(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir)

            append_quality_report(output_dir, "Quality: good")

            report = (output_dir / "track-downloader-quality-report.txt").read_text(encoding="utf-8")
            self.assertIn("Quality: good", report)

    def test_open_contained_append_file_rejects_parent_path_components(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            workspace = Path(temp_dir)
            output_dir = workspace / "output"
            outside = workspace / "outside.txt"

            try:
                with self.assertRaises(ValueError):
                    open_contained_append_file(output_dir, "../outside.txt")
            finally:
                outside.unlink(missing_ok=True)

    def test_append_quality_report_rejects_a_root_swapped_to_an_outside_symlink_before_open(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            workspace = Path(temp_dir)
            output_dir = workspace / "output"
            moved_output_dir = workspace / "moved-output"
            outside_dir = workspace / "outside"
            outside_report = outside_dir / "track-downloader-quality-report.txt"
            output_dir.mkdir()
            outside_dir.mkdir()
            resolved_output_dir = output_dir.resolve()
            original_open = os.open
            swapped = False

            def swap_output_root(path, *args, **kwargs):
                nonlocal swapped
                if not swapped and Path(path) == resolved_output_dir:
                    swapped = True
                    output_dir.rename(moved_output_dir)
                    output_dir.symlink_to(outside_dir, target_is_directory=True)
                return original_open(path, *args, **kwargs)

            with patch("track_downloader.app.os.open", side_effect=swap_output_root):
                with self.assertRaises(OSError):
                    append_quality_report(output_dir, "race-proof")

            self.assertTrue(swapped)
            self.assertFalse(outside_report.exists())

    def test_append_quality_report_allows_an_intentionally_configured_root_symlink(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            workspace = Path(temp_dir)
            configured_output_dir = workspace / "configured-output"
            actual_output_dir = workspace / "actual-output"
            actual_output_dir.mkdir()
            configured_output_dir.symlink_to(actual_output_dir, target_is_directory=True)

            append_quality_report(configured_output_dir, "Quality: good")

            report = (actual_output_dir / "track-downloader-quality-report.txt").read_text(encoding="utf-8")
            self.assertIn("Quality: good", report)


if __name__ == "__main__":
    unittest.main()
