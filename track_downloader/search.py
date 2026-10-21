from __future__ import annotations

import re
import webbrowser
from pathlib import Path
from urllib.parse import quote_plus


def search_terms_from_audio_path(path: Path) -> str:
    stem = path.stem
    stem = re.sub(r"\s*\[[^\]]+\]\s*$", "", stem)
    stem = stem.replace(" - ", " ")
    stem = re.sub(r"\s+", " ", stem).strip()
    return stem or path.stem


def build_higher_quality_search_urls(terms: str) -> list[str]:
    basic = quote_plus(terms)
    lossless = quote_plus(f"{terms} lossless wav flac aiff download")
    return [
        f"https://bandcamp.com/search?q={basic}",
        f"https://www.beatport.com/search?q={basic}",
        f"https://soundcloud.com/search?q={basic}",
        f"https://www.google.com/search?q={lossless}",
    ]


def open_higher_quality_searches(terms: str) -> None:
    for url in build_higher_quality_search_urls(terms):
        webbrowser.open(url, new=2)
