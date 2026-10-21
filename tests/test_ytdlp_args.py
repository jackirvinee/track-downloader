import unittest
from pathlib import Path

from track_downloader.cli import build_parser
from track_downloader.ytdlp_args import DownloadOptions, build_ytdlp_command


class CliParserTests(unittest.TestCase):
    def test_default_output_dir_is_track_downloader_downloads_folder(self):
        args = build_parser().parse_args(["https://youtu.be/example"])

        self.assertEqual(args.output_dir, Path("~/Downloads/Track Downloader"))


class BuildYtDlpCommandTests(unittest.TestCase):
    def test_default_command_preserves_best_source_audio_with_metadata_artwork(self):
        command = build_ytdlp_command(
            ["https://youtu.be/example"],
            DownloadOptions(output_dir=Path("/tmp/dj-library")),
        )

        self.assertEqual(command[0], "yt-dlp")
        self.assertIn("--format", command)
        self.assertIn("bestaudio/best", command)
        self.assertIn("--format-sort", command)
        self.assertIn("acodec,abr,asr", command)
        self.assertIn("--extract-audio", command)
        self.assertIn("--audio-format", command)
        self.assertIn("best", command)
        self.assertIn("--embed-metadata", command)
        self.assertIn("--embed-thumbnail", command)
        self.assertIn("--convert-thumbnails", command)
        self.assertIn("jpg", command)
        self.assertIn("--write-info-json", command)
        self.assertIn("--download-archive", command)
        self.assertIn("/tmp/dj-library/.track-downloader-archive.txt", command)
        self.assertIn("--no-playlist", command)
        self.assertEqual(command[-1], "https://youtu.be/example")

    def test_m4a_compatibility_mode_requests_m4a_without_changing_quality_setting(self):
        command = build_ytdlp_command(
            ["https://soundcloud.com/artist/track"],
            DownloadOptions(output_dir=Path("/tmp/dj-library"), audio_format="m4a"),
        )

        audio_format_index = command.index("--audio-format")
        self.assertEqual(command[audio_format_index + 1], "m4a")
        self.assertNotIn("--audio-quality", command)

    def test_mp3_mode_uses_best_vbr_quality_for_explicit_compatibility_exports(self):
        command = build_ytdlp_command(
            ["https://youtu.be/example"],
            DownloadOptions(output_dir=Path("/tmp/dj-library"), audio_format="mp3"),
        )

        audio_format_index = command.index("--audio-format")
        audio_quality_index = command.index("--audio-quality")
        self.assertEqual(command[audio_format_index + 1], "mp3")
        self.assertEqual(command[audio_quality_index + 1], "0")

    def test_playlist_downloads_must_be_enabled_explicitly(self):
        default_command = build_ytdlp_command(
            ["https://youtube.com/playlist?list=example"],
            DownloadOptions(output_dir=Path("/tmp/dj-library")),
        )
        playlist_command = build_ytdlp_command(
            ["https://youtube.com/playlist?list=example"],
            DownloadOptions(output_dir=Path("/tmp/dj-library"), playlist=True),
        )

        self.assertIn("--no-playlist", default_command)
        self.assertNotIn("--no-playlist", playlist_command)

    def test_archive_can_be_disabled(self):
        command = build_ytdlp_command(
            ["https://youtu.be/example"],
            DownloadOptions(output_dir=Path("/tmp/dj-library"), use_archive=False),
        )

        self.assertNotIn("--download-archive", command)
        self.assertNotIn("/tmp/dj-library/.track-downloader-archive.txt", command)

    def test_cookie_source_and_extra_ytdlp_args_are_appended_before_urls(self):
        command = build_ytdlp_command(
            ["https://youtu.be/example"],
            DownloadOptions(
                output_dir=Path("/tmp/dj-library"),
                cookies_from_browser="chrome",
                extra_ytdlp_args=["--verbose"],
            ),
        )

        cookies_index = command.index("--cookies-from-browser")
        verbose_index = command.index("--verbose")
        self.assertEqual(command[cookies_index + 1], "chrome")
        self.assertLess(verbose_index, len(command) - 1)
        self.assertEqual(command[-1], "https://youtu.be/example")


if __name__ == "__main__":
    unittest.main()
