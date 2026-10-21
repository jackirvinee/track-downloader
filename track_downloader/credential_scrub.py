"""Keep browser cookies out of the ``.info.json`` sidecars yt-dlp writes.

With ``--cookies-from-browser``, yt-dlp copies every cookie matching a stream's address into
that format's ``cookies`` field, and ``--write-info-json`` saves it beside the track.
"""

from __future__ import annotations

import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Any

_SENSITIVE_HEADERS = {"cookie", "authorization"}


def scrub_info_dict(value: Any, in_headers: bool = False) -> tuple[Any, bool]:
    """Return the value without cookies or credential headers, and whether anything was removed."""
    if isinstance(value, dict):
        removed = False
        result = {}
        for key, child in value.items():
            if (not in_headers and key == "cookies") or (in_headers and key.lower() in _SENSITIVE_HEADERS):
                removed = True
                continue
            result[key], child_removed = scrub_info_dict(child, in_headers=key == "http_headers")
            removed = removed or child_removed
        return result, removed
    if isinstance(value, list):
        items = [scrub_info_dict(item) for item in value]
        return [item for item, _ in items], any(removed for _, removed in items)
    return value, False


def scrub_info_json_files(output_dir: Path, since: float) -> int:
    """Scrub sidecars under ``output_dir`` modified since ``since``; return how many changed."""
    changed = 0
    cutoff = since - 2
    for root, _dirs, files in os.walk(output_dir, followlinks=False):
        for name in files:
            if not name.endswith(".info.json"):
                continue
            path = Path(root) / name
            try:
                status = path.lstat()
                if not stat.S_ISREG(status.st_mode) or status.st_mtime < cutoff:
                    continue
                cleaned, removed = scrub_info_dict(json.loads(path.read_text(encoding="utf-8")))
            except (OSError, ValueError):
                continue
            if not removed:
                continue
            descriptor, temporary = tempfile.mkstemp(prefix=".track-downloader-scrub-", dir=root)
            try:
                with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                    json.dump(cleaned, handle, ensure_ascii=False)
                os.chmod(temporary, 0o644)
                os.replace(temporary, path)
                changed += 1
            except OSError:
                Path(temporary).unlink(missing_ok=True)
    return changed
