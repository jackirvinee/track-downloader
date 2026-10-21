"""Make downloads load on every Pioneer/AlphaTheta deck. Mirrors CDJCompatibility.swift.

The rules are the strictest common denominator of the decks a DJ is likely to meet
(CDJ-900NXS, CDJ-2000/NXS/NXS2, CDJ-3000, XDJ-RX/XZ, Opus Quad):

- MP3 at 32, 44.1 or 48 kHz (16-24 kHz MPEG-2 MP3 is only a warning).
- AAC-LC in .m4a/.mp4; HE-AAC fails on older decks.
- WAV/AIFF holding 16- or 24-bit integer PCM at 44.1 or 48 kHz.
- At most two channels.
- No FLAC/ALAC (NXS2/3000 only) and no Opus/Vorbis (no deck).
- The extension must match the codec: decks pick the decoder from the extension.

After a download, AAC/MP3 in the wrong container is remuxed and everything else that fails
becomes WAV: 24-bit (16-bit when the source is 16-bit or lossy) at 44.1 or 48 kHz. The new
file keeps the name stem, so the .info.json sidecar still matches, and replaces the download
the way yt-dlp's own audio extraction replaces its input. No other file is ever overwritten.
"""

from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import uuid
from dataclasses import dataclass
from pathlib import Path

UNIVERSAL_PCM_RATES = {44100, 48000}
MP3_RATES = {32000, 44100, 48000}
MP3_LOW_RATES = {16000, 22050, 24000}
AAC_RATES = {16000, 22050, 24000, 32000, 44100, 48000}
PCM_BITS = {"pcm_s16le": 16, "pcm_s24le": 24, "pcm_s16be": 16, "pcm_s24be": 24,
            "pcm_s32le": 32, "pcm_s32be": 32, "pcm_f32le": 32, "pcm_f32be": 32,
            "pcm_f64le": 64, "pcm_f64be": 64, "pcm_u8": 8, "pcm_s8": 8}
EXT_CODECS = {".mp3": {"mp3"}, ".m4a": {"aac"}, ".mp4": {"aac"}, ".wav": set(PCM_BITS), ".aif": set(PCM_BITS),
              ".aiff": set(PCM_BITS)}
FAT32_FORBIDDEN = re.compile(r'[\\:*?"<>|]')
TEMPORARY_PREFIX = ".track-downloader-"
PROBE_ARGS = ("-v", "error", "-show_format", "-show_streams", "-of", "json", "/dev/fd/0")

ISSUE_TITLES = {
    "UNREADABLE": "Broken or not a real audio file",
    "NOT_AUDIO": "No audio stream (video file)",
    "EXT_MISMATCH": "Extension doesn't match the format",
    "UNSUPPORTED_FORMAT": "Format not supported on all decks",
    "BIT_DEPTH": "Bit depth CDJs can't play",
    "SAMPLE_RATE": "Sample rate not supported",
    "AAC_PROFILE": "HE-AAC (older decks can't decode)",
    "MP3_LOW_RATE": "Low sample-rate MP3",
    "FAT32_NAME": "Characters FAT32 doesn't allow",
}
WARNINGS = {"MP3_LOW_RATE"}
INFOS = {"FAT32_NAME"}


@dataclass(frozen=True)
class Issue:
    code: str
    detail: str = ""

    @property
    def severity(self) -> str:
        return "warning" if self.code in WARNINGS else "info" if self.code in INFOS else "error"

    @property
    def summary(self) -> str:
        title = ISSUE_TITLES[self.code]
        return f"{title} ({self.detail})" if self.detail else title


@dataclass(frozen=True)
class Probe:
    codec: str | None
    profile: str | None = None
    sample_rate: int = 0
    channels: int = 2
    bits_per_raw_sample: int | None = None
    duration: float | None = None
    has_video: bool = False
    tags_on_audio_stream: bool = False


@dataclass(frozen=True)
class Action:
    kind: str  # keep | remux | wav | cannot_fix
    extension: str | None = None
    bit_depth: int | None = None
    sample_rate: int | None = None
    downmix: bool = False
    reason: str = ""

    @property
    def summary(self) -> str:
        if self.kind == "keep":
            return "already plays on every deck"
        if self.kind == "remux":
            return f"rewrapped as .{self.extension} (audio untouched)"
        if self.kind == "wav":
            stereo = ", stereo" if self.downmix else ""
            return f"converted to {self.bit_depth}-bit WAV, {_khz(self.sample_rate or 0)}{stereo}"
        return self.reason


@dataclass(frozen=True)
class Outcome:
    path: Path
    status: str  # already_safe | converted | left_as_downloaded
    action: Action | None = None
    reason: str = ""

    @property
    def summary(self) -> str:
        if self.status == "already_safe":
            return "CDJ-safe"
        if self.status == "converted" and self.action is not None:
            return f"CDJ-safe: {self.action.summary}"
        return f"not CDJ-safe: {self.reason}"


def _khz(hertz: int) -> str:
    return f"{hertz / 1000:g} kHz"


def _int(value: object) -> int | None:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None


def _has_track_tags(tags: object) -> bool:
    return isinstance(tags, dict) and any(str(key).lower() in ("title", "artist") for key in tags)


def parse_probe(ffprobe_json: str) -> Probe | None:
    """Parse `ffprobe -show_format -show_streams -of json`; None when no container was read."""
    try:
        data = json.loads(ffprobe_json or "{}")
    except json.JSONDecodeError:
        return None
    fmt = data.get("format")
    if not isinstance(fmt, dict):
        return None
    streams = data.get("streams") or []
    audio = next((s for s in streams if s.get("codec_type") == "audio"), None)
    has_video = any(
        s.get("codec_type") == "video" and not (s.get("disposition") or {}).get("attached_pic") for s in streams
    )
    duration = fmt.get("duration")
    try:
        duration_seconds = float(duration) if duration is not None else None
    except (TypeError, ValueError):
        duration_seconds = None
    if audio is None:
        return Probe(codec=None, channels=0, duration=duration_seconds, has_video=has_video)
    return Probe(
        codec=audio.get("codec_name"),
        profile=audio.get("profile"),
        sample_rate=_int(audio.get("sample_rate")) or 0,
        channels=_int(audio.get("channels")) or 0,
        bits_per_raw_sample=_int(audio.get("bits_per_raw_sample")),
        duration=duration_seconds,
        has_video=has_video,
        tags_on_audio_stream=_has_track_tags(audio.get("tags")) and not _has_track_tags(fmt.get("tags")),
    )


def check(probe: Probe | None, extension: str) -> list[Issue]:
    """CDJ issues for a probed file. `extension` includes the dot, e.g. ".flac"."""
    if probe is None:
        return [Issue("UNREADABLE")]
    codec = probe.codec
    if codec is None:
        return [Issue("NOT_AUDIO")] if probe.has_video else [Issue("UNREADABLE", "no audio stream")]
    ext, rate = extension.lower(), probe.sample_rate
    issues: list[Issue] = []
    expected = EXT_CODECS.get(ext)
    if expected is None:
        issues.append(Issue("UNSUPPORTED_FORMAT", ext or codec))
    elif codec not in expected:
        issues.append(Issue("UNSUPPORTED_FORMAT", "ALAC") if codec == "alac" else Issue("EXT_MISMATCH", f"{codec} in {ext}"))
    if codec in PCM_BITS:
        bits = PCM_BITS[codec]
        if bits not in (16, 24):
            issues.append(Issue("BIT_DEPTH", f"{bits}-bit{' float' if '_f' in codec else ''}"))
        if rate not in UNIVERSAL_PCM_RATES:
            issues.append(Issue("SAMPLE_RATE", _khz(rate)))
    elif codec == "mp3":
        if rate in MP3_LOW_RATES:
            issues.append(Issue("MP3_LOW_RATE", _khz(rate)))
        elif rate not in MP3_RATES:
            issues.append(Issue("SAMPLE_RATE", _khz(rate)))
    elif codec == "aac":
        if probe.profile and "HE" in probe.profile:
            issues.append(Issue("AAC_PROFILE", probe.profile))
        if rate not in AAC_RATES:
            issues.append(Issue("SAMPLE_RATE", _khz(rate)))
    if probe.channels > 2:
        issues.append(Issue("UNSUPPORTED_FORMAT", f"{probe.channels} channels"))
    return issues


def file_name_issue(name: str) -> Issue | None:
    return Issue("FAT32_NAME") if FAT32_FORBIDDEN.search(name) else None


def target_sample_rate(hertz: int) -> int:
    """44.1 and 48 kHz stay; multiples of 48 kHz go to 48 kHz; everything else to 44.1 kHz."""
    if hertz in UNIVERSAL_PCM_RATES:
        return hertz
    return 48000 if hertz > 48000 and hertz % 48000 == 0 else 44100


def plan(probe: Probe | None, extension: str) -> Action:
    errors = [i for i in check(probe, extension) if i.severity == "error"]
    if not errors:
        return Action("keep")
    if probe is None or probe.codec is None:
        return Action("cannot_fix", reason="; ".join(i.summary for i in errors))
    codec = probe.codec
    he_aac = "HE" in (probe.profile or "")
    if all(i.code == "EXT_MISMATCH" for i in errors) and codec in ("aac", "mp3") and not he_aac:
        return Action("remux", extension="m4a" if codec == "aac" else "mp3")
    bits = PCM_BITS.get(codec) or ((probe.bits_per_raw_sample or 24) if codec in ("flac", "alac") else 16)
    return Action("wav", extension="wav", bit_depth=16 if bits <= 16 else 24,
                  sample_rate=target_sample_rate(probe.sample_rate), downmix=probe.channels > 2)


def ffmpeg_args(action: Action, input_path: str, output_path: str, probe: Probe) -> list[str]:
    """ffmpeg arguments that write the CDJ-safe copy. `-n` never overwrites an existing file."""
    base = ["-nostdin", "-v", "error", "-n", "-i", input_path, "-map", "0:a:0",
            "-map_metadata", "0:s:a:0" if probe.tags_on_audio_stream else "0"]
    if action.kind == "remux":
        faststart = ["-movflags", "+faststart"] if action.extension == "m4a" else []
        return [*base, "-c:a", "copy", *faststart, output_path]
    if action.kind == "wav":
        downmix = ["-ac", "2"] if action.downmix else []
        codec = "pcm_s16le" if action.bit_depth == 16 else "pcm_s24le"
        return [*base, "-c:a", codec, "-ar", str(action.sample_rate), *downmix, output_path]
    return []


def verification_problem(source: Probe, converted: Probe | None, extension: str) -> str | None:
    """Why a converted copy must not replace the download, or None when it's good."""
    if converted is None or converted.codec is None:
        return "the converted file is unreadable"
    failure = next((i for i in check(converted, extension) if i.severity == "error"), None)
    if failure is not None:
        return f"the converted file still fails: {failure.summary}"
    before, after = source.duration, converted.duration
    if before is not None and after is not None and abs(before - after) > max(0.2, before * 0.01):
        return f"the length changed ({before:.2f}s to {after:.2f}s)"
    return None


class _Refused(Exception):
    pass


def _open_regular(path: Path) -> int:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0))
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise _Refused("not a regular file")
    return descriptor


def probe_file(path: Path, ffprobe: str = "ffprobe") -> Probe | None:
    """Probe through the opened file (seekable /dev/fd/0), never following a symlink."""
    try:
        descriptor = _open_regular(path)
    except (OSError, _Refused):
        return None
    try:
        result = subprocess.run([ffprobe, *PROBE_ARGS], stdin=descriptor, capture_output=True, text=True,
                                errors="replace", check=False)
    except OSError:
        return None
    finally:
        os.close(descriptor)
    return parse_probe(result.stdout) if result.returncode == 0 else None


def _contained(path: Path, output_root: Path) -> bool:
    try:
        return not path.is_symlink() and path.resolve(strict=True).is_relative_to(output_root.resolve(strict=True))
    except OSError:
        return False


def make_cdj_safe(path: Path, output_root: Path, *, ffmpeg: str = "ffmpeg", ffprobe: str = "ffprobe") -> Outcome:
    """Replace a download some decks can't load with one every deck loads; see the module docstring."""
    if not _contained(path, output_root):
        return Outcome(path, "left_as_downloaded", reason="not a regular file in the download folder")
    probe = probe_file(path, ffprobe)
    action = plan(probe, path.suffix)
    if action.kind == "keep":
        return Outcome(path, "already_safe", action)
    if action.kind == "cannot_fix" or probe is None or action.extension is None:
        return Outcome(path, "left_as_downloaded", action, reason=action.summary)

    target = path.with_suffix(f".{action.extension}")
    replaces_download = target.name.lower() == path.name.lower()  # APFS is usually case-insensitive
    if not replaces_download and os.path.lexists(target):
        return Outcome(path, "left_as_downloaded", action, reason=f"{target.name} already exists")
    temporary = path.parent / f"{TEMPORARY_PREFIX}{uuid.uuid4().hex}.{action.extension}"
    try:
        descriptor = _open_regular(path)
        try:
            result = subprocess.run([ffmpeg, *ffmpeg_args(action, "/dev/fd/0", str(temporary), probe)],
                                    stdin=descriptor, capture_output=True, text=True, errors="replace", check=False)
        finally:
            os.close(descriptor)
        if result.returncode != 0:
            raise _Refused("ffmpeg couldn't convert it")
        problem = verification_problem(probe, probe_file(temporary, ffprobe), f".{action.extension}")
        if problem:
            raise _Refused(problem)
        if replaces_download:
            os.replace(temporary, path)
            return Outcome(path, "converted", action)
        os.link(temporary, target)  # fails rather than overwrite if the name appeared meanwhile
        os.unlink(temporary)
        try:
            os.unlink(path)
        except OSError:
            pass
        return Outcome(target, "converted", action)
    except (OSError, _Refused) as exc:
        if os.path.lexists(temporary) and not temporary.is_symlink():
            temporary.unlink()
        reason = str(exc) if isinstance(exc, _Refused) else "it couldn't be converted"
        return Outcome(path, "left_as_downloaded", action, reason=reason)
