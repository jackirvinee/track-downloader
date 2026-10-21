import json
import os
import tempfile
import time
import unittest
from pathlib import Path

from track_downloader.credential_scrub import scrub_info_dict, scrub_info_json_files


class CredentialScrubTests(unittest.TestCase):
    def test_removes_format_cookies_and_credential_headers(self):
        info = {
            "title": "Night Drive",
            "cookies": "oauth_token=SECRET",
            "http_headers": {"User-Agent": "x", "Cookie": "a=SECRET", "Authorization": "OAuth SECRET"},
            "formats": [{"format_id": "download", "cookies": "SECRET"}],
            "tags": ["cookies"],
        }
        cleaned, removed = scrub_info_dict(info)
        self.assertTrue(removed)
        self.assertNotIn("SECRET", json.dumps(cleaned))
        self.assertEqual(cleaned["http_headers"], {"User-Agent": "x"})
        self.assertEqual(cleaned["tags"], ["cookies"])

    def test_rewrites_only_recent_sidecars_with_cookies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Soundcloud").mkdir()
            fresh = root / "Soundcloud" / "A - B [1].info.json"
            fresh.write_text(json.dumps({"title": "B", "formats": [{"cookies": "SECRET"}]}), encoding="utf-8")
            old = root / "Old.info.json"
            old.write_text(json.dumps({"cookies": "left alone"}), encoding="utf-8")
            os.utime(old, (time.time() - 3600, time.time() - 3600))
            clean = root / "Clean.info.json"
            clean.write_text('{"title": "C"}', encoding="utf-8")

            changed = scrub_info_json_files(root, time.time() - 60)

            self.assertEqual(changed, 1)
            self.assertNotIn("SECRET", fresh.read_text(encoding="utf-8"))
            self.assertIn("left alone", old.read_text(encoding="utf-8"))
            self.assertEqual(clean.read_text(encoding="utf-8"), '{"title": "C"}')
            self.assertEqual(sorted(p.name for p in (root / "Soundcloud").iterdir()), [fresh.name])


if __name__ == "__main__":
    unittest.main()
