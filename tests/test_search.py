import unittest
from pathlib import Path
from urllib.parse import unquote_plus, urlparse

from track_downloader.search import build_higher_quality_search_urls, search_terms_from_audio_path


class SearchTests(unittest.TestCase):
    def test_search_terms_remove_ytdlp_id_suffix_and_extension(self):
        terms = search_terms_from_audio_path(Path("SoundCloud/Artist Name - Track Title [abc123].opus"))

        self.assertEqual(terms, "Artist Name Track Title")

    def test_search_terms_keep_simple_track_names(self):
        terms = search_terms_from_audio_path(Path("Unknown Track.m4a"))

        self.assertEqual(terms, "Unknown Track")

    def test_higher_quality_urls_target_legal_source_searches(self):
        urls = build_higher_quality_search_urls("Artist Name Track Title")
        hosts = {urlparse(url).netloc for url in urls}
        decoded = " ".join(unquote_plus(url) for url in urls)

        self.assertIn("bandcamp.com", hosts)
        self.assertIn("www.beatport.com", hosts)
        self.assertIn("soundcloud.com", hosts)
        self.assertIn("www.google.com", hosts)
        self.assertIn("Artist Name Track Title", decoded)
        self.assertIn("lossless", decoded)


if __name__ == "__main__":
    unittest.main()
