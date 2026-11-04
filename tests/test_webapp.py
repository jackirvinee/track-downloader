import json
import http.client
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from track_downloader.webapp import (
    MAX_JSON_BODY_BYTES,
    JobState,
    TrackDownloaderRequestHandler,
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

    def test_unexpected_job_failure_ends_the_running_state(self):
        server = TrackDownloaderServer(("127.0.0.1", 0))
        self.addCleanup(server.server_close)
        server.state = JobState(status="running", message="Downloading...")
        handler = TrackDownloaderRequestHandler.__new__(TrackDownloaderRequestHandler)
        handler.server = server

        with (
            patch("track_downloader.webapp.run_download", side_effect=RuntimeError("scan failed")),
            patch("track_downloader.app.append_quality_report") as append_report,
        ):
            handler.run_job(["yt-dlp", "https://www.youtube.com/watch?v=fixture"])

        self.assertEqual(server.state.status, "error")
        self.assertTrue(server.state.is_error)
        self.assertIn("scan failed", server.state.message)
        append_report.assert_called_once()


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

    def test_concurrent_download_requests_start_only_one_job(self):
        both_validated = threading.Barrier(2, timeout=2)
        release_job = threading.Event()
        started_jobs: list[list[str]] = []

        def tools_present_after_both_requests_arrive(_yt_dlp: str) -> list[str]:
            # Hold both requests between validation and job start, where the
            # single-download guard used to be released.
            both_validated.wait()
            return []

        def blocking_job(_handler, command: list[str]) -> None:
            started_jobs.append(command)
            release_job.wait(timeout=2)

        headers = {
            "X-TrackDownloader-Session": self.server.session_token,
            "Content-Type": "application/json",
        }
        body = json.dumps({"url": "https://www.youtube.com/watch?v=fixture"}).encode("utf-8")
        statuses: list[int] = []

        def post() -> None:
            status, _, _ = self.request("POST", "/api/download", body=body, headers=headers)
            statuses.append(status)

        with (
            patch("track_downloader.webapp._missing_runtime_tools", tools_present_after_both_requests_arrive),
            patch.object(TrackDownloaderRequestHandler, "run_job", blocking_job),
        ):
            clients = [threading.Thread(target=post) for _ in range(2)]
            for client in clients:
                client.start()
            for client in clients:
                client.join(timeout=3)
            release_job.set()

        self.assertEqual(sorted(statuses), [200, 409])
        self.assertEqual(len(started_jobs), 1)

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
