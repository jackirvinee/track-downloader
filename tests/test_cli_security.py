import contextlib
import io
import unittest

from track_downloader.cli import main


class CLISecurityTests(unittest.TestCase):
    def test_rejects_non_https_and_unsupported_hosts_before_dry_run(self):
        for value in (
            "http://soundcloud.com/artist/track",
            "https://example.com/track",
        ):
            with self.subTest(value=value):
                with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(SystemExit) as raised:
                        main(["--dry-run", value])
                self.assertEqual(raised.exception.code, 2)

    def test_accepts_supported_https_host_for_dry_run(self):
        output = io.StringIO()

        with contextlib.redirect_stdout(output):
            result = main(["--dry-run", " https://music.youtube.com/watch?v=example "])

        self.assertEqual(result, 0)
        self.assertIn("https://music.youtube.com/watch?v=example", output.getvalue())


if __name__ == "__main__":
    unittest.main()
