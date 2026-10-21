from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO


AUDIO_EXTENSIONS = {
    ".aac",
    ".aif",
    ".aiff",
    ".alac",
    ".flac",
    ".m4a",
    ".mp3",
    ".oga",
    ".ogg",
    ".opus",
    ".wav",
    ".webm",
}


@dataclass(frozen=True)
class AudioQuality:
    path: Path
    codec: str
    kbps: int | None
    sample_rate_hz: int | None
    verdict: str

    def summary(self) -> str:
        bitrate = "unknown bitrate" if self.kbps is None else f"{self.kbps} kbps"
        sample_rate = "" if self.sample_rate_hz is None else f", {self.sample_rate_hz / 1000:g} kHz"
        return f"{bitrate} {self.codec}{sample_rate} - {self.verdict}"


def classify_kbps(kbps: int | None) -> str:
    if kbps is None:
        return "unknown"
    if kbps >= 256:
        return "excellent"
    if kbps >= 160:
        return "good"
    if kbps >= 128:
        return "borderline"
    return "low"


def parse_ffprobe_audio_quality(ffprobe_json: str, path: Path) -> AudioQuality:
    payload = json.loads(ffprobe_json)
    audio_streams = [
        stream for stream in payload.get("streams", []) if stream.get("codec_type") == "audio"
    ]
    stream = audio_streams[0] if audio_streams else {}
    codec = str(stream.get("codec_name") or "unknown")
    bit_rate = _parse_int(stream.get("bit_rate"))
    if bit_rate is None:
        bit_rate = _parse_int(payload.get("format", {}).get("bit_rate"))
    sample_rate_hz = _parse_int(stream.get("sample_rate"))
    kbps = None if bit_rate is None else round(bit_rate / 1000)
    return AudioQuality(
        path=path,
        codec=codec,
        kbps=kbps,
        sample_rate_hz=sample_rate_hz,
        verdict=classify_kbps(kbps),
    )


def inspect_audio_quality(path: Path, *, standard_input: BinaryIO | None = None) -> AudioQuality:
    input_target = "pipe:0" if standard_input is not None else str(path)
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "stream=codec_type,codec_name,bit_rate,sample_rate:format=bit_rate",
            "-of",
            "json",
            input_target,
        ],
        check=True,
        capture_output=True,
        text=True,
        stdin=standard_input,
    )
    return parse_ffprobe_audio_quality(result.stdout, path)


def find_newest_audio_file(root: Path, since: float) -> Path | None:
    if not root.exists():
        return None

    resolved_root = root.resolve()
    candidates = [
        path
        for path in root.rglob("*")
        if path.is_file()
        and path.resolve().is_relative_to(resolved_root)
        and path.suffix.lower() in AUDIO_EXTENSIONS
        and path.stat().st_mtime >= since
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def _parse_int(value: object) -> int | None:
    if value in (None, "", "N/A"):
        return None
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
