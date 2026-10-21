import json
import http.client
import threading
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from track_downloader.webapp import (
    MAX_JSON_BODY_BYTES,
    JobState,
    TrackDownloaderServer,
    build_browser_launch_url,
    build_status_payload,
    render_index_html,
)


class WebAppTests(unittest.TestCase):
    def test_index_html_contains_mini_app_controls_without_a_session_token(self):
        html = render_index_html()

        self.assertIn("Track Downloader", html)
        self.assertIn("~/Downloads/Track Downloader", html)
        self.assertIn("Paste a YouTube or SoundCloud link", html)
        self.assertIn("/api/download", html)
        self.assertIn("/api/status", html)
        self.assertIn("/api/quit", html)
        self.assertIn("quality", html.lower())
        self.assertIn("X-TrackDownloader-Session", html)
        self.assertNotIn("?token=", html)

    def test_status_payload_includes_download_result(self):
        state = JobState(
            status="done",
            message="Downloaded: Artist - Track.opus\nQuality: 160 kbps opus - good",
            audio_file=Path("/tmp/Artist - Track.opus"),
            offer_search=False,
            is_error=False,
        )

        payload = build_status_payload(state)

        self.assertEqual(payload["status"], "done")
        self.assertEqual(payload["audioFile"], "/tmp/Artist - Track.opus")
        self.assertFalse(payload["offerSearch"])
        json.dumps(payload)

    def test_status_payload_omits_missing_audio_file(self):
        payload = build_status_payload(JobState())

        self.assertEqual(payload["status"], "idle")
        self.assertIsNone(payload["audioFile"])


class WebAppSecurityTests(unittest.TestCase):
    def setUp(self):
        self.server = TrackDownloaderServer(("127.0.0.1", 0))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(
        self,
        method: str,
        path: str,
        *,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        host, port = self.server.server_address
        connection = http.client.HTTPConnection(host, port, timeout=2)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        response_body = response.read()
        response_headers = {key.lower(): value for key, value in response.getheaders()}
        connection.close()
        return response.status, response_headers, response_body

    def test_state_changing_requests_require_the_per_launch_token(self):
        status, _, _ = self.request("POST", "/api/search")
        self.assertEqual(status, 403)

        status, _, _ = self.request(
            "POST",
            "/api/search",
            headers={"X-TrackDownloader-Session": "wrong-token"},
        )
        self.assertEqual(status, 403)

        status, _, body = self.request(
            "POST",
            "/api/search",
            headers={"X-TrackDownloader-Session": self.server.session_token},
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["message"], "Search opened.")

        status, _, _ = self.request(
            "POST",
            "/api/search",
            headers={
                "X-TrackDownloader-Session": self.server.session_token,
                "Origin": "https://malicious.example",
            },
        )
        self.assertEqual(status, 403)

    def test_download_rejects_non_json_and_oversized_bodies(self):
        headers = {
            "X-TrackDownloader-Session": self.server.session_token,
            "Content-Type": "text/plain",
        }
        status, _, _ = self.request("POST", "/api/download", body=b"{}", headers=headers)
        self.assertEqual(status, 415)

        headers["Content-Type"] = "application/json"
        body = b"{" + b" " * MAX_JSON_BODY_BYTES + b"}"
        status, _, _ = self.request("POST", "/api/download", body=body, headers=headers)
        self.assertEqual(status, 413)

    def test_responses_include_defensive_browser_headers(self):
        status, headers, _ = self.request("GET", "/")

        self.assertEqual(status, 200)
        self.assertEqual(headers["cache-control"], "no-store")
        self.assertEqual(headers["x-content-type-options"], "nosniff")
        self.assertEqual(headers["referrer-policy"], "no-referrer")
        self.assertIn("frame-ancestors 'none'", headers["content-security-policy"])

    def test_loopback_landing_page_does_not_disclose_the_api_bearer_token(self):
        status, _, body = self.request("GET", "/")

        self.assertEqual(status, 200)
        self.assertNotIn(self.server.session_token.encode("utf-8"), body)

    def test_browser_launch_url_keeps_the_session_token_out_of_the_http_request(self):
        host, port = self.server.server_address
        launch_url = urlsplit(build_browser_launch_url(host, port, self.server.session_token))

        self.assertEqual(launch_url.scheme, "http")
        self.assertEqual(launch_url.netloc, f"{host}:{port}")
        self.assertEqual(launch_url.path, "/")
        self.assertEqual(launch_url.query, "")
        self.assertEqual(parse_qs(launch_url.fragment), {"session": [self.server.session_token]})

    def test_status_requires_token_and_foreign_host_is_rejected(self):
        status, _, _ = self.request("GET", "/api/status")
        self.assertEqual(status, 403)

        status, _, _ = self.request(
            "GET",
            "/api/status",
            headers={"X-TrackDownloader-Session": self.server.session_token},
        )
        self.assertEqual(status, 200)

        status, _, _ = self.request("GET", "/", headers={"Host": "malicious.example"})
        self.assertEqual(status, 403)


if __name__ == "__main__":
    unittest.main()
