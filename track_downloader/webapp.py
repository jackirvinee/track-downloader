from __future__ import annotations

import hmac
import json
import secrets
import threading
import webbrowser
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from track_downloader.app import build_gui_download_command, normalize_url, run_download
from track_downloader.cli import DEFAULT_OUTPUT_DIR, _missing_runtime_tools
from track_downloader.search import open_higher_quality_searches, search_terms_from_audio_path


MAX_JSON_BODY_BYTES = 16 * 1024
REQUEST_TIMEOUT_SECONDS = 5


class RequestValidationError(ValueError):
    def __init__(self, message: str, status: int):
        super().__init__(message)
        self.status = status


@dataclass
class JobState:
    status: str = "idle"
    message: str = ""
    audio_file: Path | None = None
    offer_search: bool = False
    is_error: bool = False


def build_status_payload(state: JobState) -> dict[str, Any]:
    return {
        "status": state.status,
        "message": state.message,
        "audioFile": None if state.audio_file is None else str(state.audio_file),
        "offerSearch": state.offer_search,
        "isError": state.is_error,
    }


def render_index_html() -> str:
    template = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Track Downloader</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #0f172a;
      --panel: #111827;
      --line: #263244;
      --text: #f8fafc;
      --muted: #94a3b8;
      --cyan: #38bdf8;
      --green: #34d399;
      --warn: #fbbf24;
      --bad: #fb7185;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background: var(--bg);
      color: var(--text);
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    main {
      width: min(460px, calc(100vw - 32px));
      border: 1px solid var(--line);
      border-radius: 14px;
      background: var(--panel);
      padding: 18px;
      box-shadow: 0 18px 44px rgba(0, 0, 0, .32);
    }
    .top {
      display: flex;
      align-items: center;
      gap: 12px;
      margin-bottom: 16px;
    }
    .mark {
      width: 44px;
      height: 44px;
      border-radius: 10px;
      border: 1px solid rgba(255,255,255,.18);
      display: grid;
      place-items: center;
      color: var(--cyan);
      background: #0b1220;
    }
    h1 {
      margin: 0;
      font-size: 18px;
      letter-spacing: 0;
    }
    .sub { color: var(--muted); font-size: 12px; }
    label {
      display: block;
      color: var(--muted);
      margin-bottom: 7px;
      font-size: 12px;
    }
    .row {
      display: flex;
      gap: 8px;
    }
    input {
      width: 100%;
      min-width: 0;
      border-radius: 8px;
      border: 1px solid var(--line);
      background: #0b1220;
      color: var(--text);
      padding: 11px 12px;
      font: inherit;
      outline: none;
    }
    input:focus { border-color: var(--cyan); }
    button {
      border: 0;
      border-radius: 8px;
      background: var(--cyan);
      color: #031018;
      font-weight: 700;
      padding: 0 14px;
      min-width: 94px;
      cursor: pointer;
    }
    button:disabled { opacity: .55; cursor: default; }
    #status {
      margin-top: 14px;
      min-height: 74px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #0b1220;
      padding: 12px;
      white-space: pre-wrap;
      color: var(--muted);
    }
    #status.done { color: var(--green); }
    #status.bad { color: var(--bad); }
    #status.warn { color: var(--warn); }
    .actions {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-top: 12px;
      gap: 10px;
    }
    .path {
      color: var(--muted);
      font-size: 11px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    #searchBtn {
      display: none;
      background: transparent;
      color: var(--cyan);
      border: 1px solid var(--line);
      min-width: 132px;
      height: 34px;
    }
    #quitBtn {
      margin-left: auto;
      min-width: 54px;
      height: 30px;
      background: transparent;
      border: 1px solid var(--line);
      color: var(--muted);
      font-weight: 600;
      padding: 0 10px;
    }
    svg { display: block; }
  </style>
</head>
<body>
  <main>
    <div class="top">
      <div class="mark" aria-hidden="true">
        <svg width="28" height="28" viewBox="0 0 28 28">
          <rect x="4" y="8" width="3" height="8" rx="1.5" fill="currentColor"/>
          <rect x="9" y="5" width="3" height="14" rx="1.5" fill="currentColor"/>
          <rect x="14" y="3" width="3" height="18" rx="1.5" fill="currentColor"/>
          <rect x="19" y="7" width="3" height="10" rx="1.5" fill="currentColor"/>
          <path d="M14 25l-6-6h4v-6h4v6h4z" fill="#f8fafc"/>
        </svg>
      </div>
      <div>
        <h1>Track Downloader</h1>
        <div class="sub">Best available audio with quality reporting</div>
      </div>
      <button id="quitBtn" type="button" title="Quit Track Downloader">Quit</button>
    </div>
    <form id="form">
      <label for="url">Paste a YouTube or SoundCloud link</label>
      <div class="row">
        <input id="url" autocomplete="off" placeholder="https://soundcloud.com/artist/track">
        <button id="downloadBtn" type="submit">Download</button>
      </div>
    </form>
    <div id="status">Ready.</div>
    <div class="actions">
      <div class="path">Saves to ~/Downloads/Track Downloader</div>
      <button id="searchBtn" type="button">Find better source</button>
    </div>
  </main>
  <script>
    const sessionToken = new URLSearchParams(window.location.hash.slice(1)).get('session') || '';
    if (window.location.hash) {
      history.replaceState(null, '', window.location.pathname);
    }
    const form = document.getElementById('form');
    const input = document.getElementById('url');
    const button = document.getElementById('downloadBtn');
    const statusBox = document.getElementById('status');
    const searchBtn = document.getElementById('searchBtn');
    const quitBtn = document.getElementById('quitBtn');
    let timer = null;

    function setStatus(text, mode = '') {
      statusBox.textContent = text;
      statusBox.className = mode;
    }

    async function poll() {
      const res = await fetch('/api/status', {
        headers: {'X-TrackDownloader-Session': sessionToken}
      });
      const state = await res.json();
      if (state.status === 'running') {
        setStatus(state.message || 'Downloading...');
        return;
      }
      clearInterval(timer);
      timer = null;
      button.disabled = false;
      input.disabled = false;
      const lower = (state.message || '').toLowerCase();
      const mode = state.isError ? 'bad' : lower.includes('low quality') || lower.includes('borderline') ? 'warn' : 'done';
      setStatus(state.message || 'Ready.', mode);
      searchBtn.style.display = state.offerSearch ? 'inline-block' : 'none';
    }

    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      searchBtn.style.display = 'none';
      button.disabled = true;
      input.disabled = true;
      setStatus('Starting download...');
      const res = await fetch('/api/download', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'X-TrackDownloader-Session': sessionToken
        },
        body: JSON.stringify({url: input.value})
      });
      if (!res.ok) {
        const state = await res.json();
        button.disabled = false;
        input.disabled = false;
        setStatus(state.message || 'Could not start download.', 'bad');
        return;
      }
      timer = setInterval(poll, 900);
      poll();
    });

    searchBtn.addEventListener('click', async () => {
      await fetch('/api/search', {
        method: 'POST',
        headers: {'X-TrackDownloader-Session': sessionToken}
      });
    });

    quitBtn.addEventListener('click', async () => {
      await fetch('/api/quit', {
        method: 'POST',
        headers: {'X-TrackDownloader-Session': sessionToken}
      });
      setStatus('Track Downloader closed. You can close this tab.');
      button.disabled = true;
      input.disabled = true;
      searchBtn.style.display = 'none';
    });

    input.focus();
  </script>
</body>
</html>"""
    return template


def build_browser_launch_url(host: str, port: int, session_token: str) -> str:
    return f"http://{host}:{port}/#session={session_token}"


class TrackDownloaderServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int]):
        super().__init__(server_address, TrackDownloaderRequestHandler)
        self.state = JobState()
        self.lock = threading.Lock()
        self.session_token = secrets.token_urlsafe(32)


class TrackDownloaderRequestHandler(BaseHTTPRequestHandler):
    server: TrackDownloaderServer

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(REQUEST_TIMEOUT_SECONDS)

    def expected_host(self) -> str:
        host, port = self.server.server_address
        return f"{host}:{port}"

    def has_valid_host(self) -> bool:
        return hmac.compare_digest(self.headers.get("Host", ""), self.expected_host())

    def has_valid_token(self) -> bool:
        supplied_token = self.headers.get("X-TrackDownloader-Session", "")
        return hmac.compare_digest(supplied_token, self.server.session_token)

    def do_GET(self) -> None:
        if not self.has_valid_host():
            self.send_json({"message": "Request not authorized."}, status=403)
            return
        if self.path == "/":
            self.send_text(render_index_html(), "text/html; charset=utf-8")
            return
        if self.path == "/api/status":
            if not self.has_valid_token():
                self.send_json({"message": "Request not authorized."}, status=403)
                return
            with self.server.lock:
                payload = build_status_payload(self.server.state)
            self.send_json(payload)
            return
        self.send_error(404)

    def do_POST(self) -> None:
        host, port = self.server.server_address
        expected_origin = f"http://{host}:{port}"
        supplied_origin = self.headers.get("Origin")
        origin_matches = supplied_origin is None or hmac.compare_digest(supplied_origin, expected_origin)
        if not self.has_valid_host() or not self.has_valid_token() or not origin_matches:
            self.send_json({"message": "Request not authorized."}, status=403)
            return

        if self.path == "/api/download":
            self.handle_download()
            return
        if self.path == "/api/search":
            self.handle_search()
            return
        if self.path == "/api/quit":
            self.send_json({"message": "Track Downloader closing."})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        self.send_error(404)

    def handle_download(self) -> None:
        with self.server.lock:
            if self.server.state.status == "running":
                self.send_json({"message": "A download is already running."}, status=409)
                return

        try:
            body = self.read_json()
            url = normalize_url(str(body.get("url", "")))
            command = build_gui_download_command(url)
        except RequestValidationError as exc:
            self.send_json({"message": str(exc)}, status=exc.status)
            return
        except (ValueError, json.JSONDecodeError) as exc:
            self.send_json({"message": str(exc)}, status=400)
            return

        missing = _missing_runtime_tools("yt-dlp")
        if missing:
            self.send_json({"message": "Missing required tool(s): " + ", ".join(missing)}, status=500)
            return

        with self.server.lock:
            self.server.state = JobState(status="running", message="Downloading...")

        thread = threading.Thread(target=self.run_job, args=(command,), daemon=True)
        thread.start()
        self.send_json({"message": "Download started."})

    def run_job(self, command: list[str]) -> None:
        output_dir = DEFAULT_OUTPUT_DIR.expanduser()
        message, audio_file, offer_search, is_error = run_download(command, output_dir)
        try:
            from track_downloader.app import append_quality_report

            append_quality_report(output_dir, message.replace("\n", " | "))
        except OSError as exc:
            message = f"{message}\n\nQuality report was not written safely: {exc}"
            is_error = True
        with self.server.lock:
            self.server.state = JobState(
                status="error" if is_error else "done",
                message=message,
                audio_file=audio_file,
                offer_search=offer_search,
                is_error=is_error,
            )

    def handle_search(self) -> None:
        with self.server.lock:
            audio_file = self.server.state.audio_file
        if audio_file is not None:
            open_higher_quality_searches(search_terms_from_audio_path(audio_file))
        self.send_json({"message": "Search opened."})

    def read_json(self) -> dict[str, Any]:
        content_type = self.headers.get("content-type", "").partition(";")[0].strip().lower()
        if content_type != "application/json":
            raise RequestValidationError("Content-Type must be application/json.", status=415)

        try:
            length = int(self.headers.get("content-length", "0"))
        except ValueError as exc:
            raise RequestValidationError("Invalid Content-Length.", status=400) from exc
        if length < 0:
            raise RequestValidationError("Invalid Content-Length.", status=400)
        if length > MAX_JSON_BODY_BYTES:
            raise RequestValidationError("Request body is too large.", status=413)

        raw = self.rfile.read(length).decode("utf-8")
        payload = json.loads(raw or "{}")
        if not isinstance(payload, dict):
            raise RequestValidationError("JSON body must be an object.", status=400)
        return payload

    def send_browser_security_headers(self) -> None:
        self.send_header("cache-control", "no-store")
        self.send_header("x-content-type-options", "nosniff")
        self.send_header("referrer-policy", "no-referrer")
        self.send_header(
            "content-security-policy",
            "default-src 'none'; connect-src 'self'; script-src 'unsafe-inline'; "
            "style-src 'unsafe-inline'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
        )

    def send_json(self, payload: dict[str, Any], status: int = 200) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_browser_security_headers()
        self.end_headers()
        self.wfile.write(body)

    def send_text(self, text: str, content_type: str) -> None:
        body = text.encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(body)))
        self.send_browser_security_headers()
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: Any) -> None:
        return


def main() -> int:
    server = TrackDownloaderServer(("127.0.0.1", 0))
    host, port = server.server_address
    url = build_browser_launch_url(host, port, server.session_token)
    webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
