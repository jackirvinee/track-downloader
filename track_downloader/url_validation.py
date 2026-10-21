from __future__ import annotations

from urllib.parse import urlparse


SUPPORTED_HOSTS = ("youtube.com", "youtu.be", "soundcloud.com")


def normalize_url(value: str) -> str:
    url = value.strip()
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    is_supported_host = any(host == allowed or host.endswith(f".{allowed}") for allowed in SUPPORTED_HOSTS)
    if (
        parsed.scheme.lower() != "https"
        or not host
        or not is_supported_host
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise ValueError("Paste a YouTube or SoundCloud link.")
    return url
