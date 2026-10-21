import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

from track_downloader import cdj_safe
from track_downloader.cdj_safe import Action, Issue, Probe, check, ffmpeg_args, make_cdj_safe, parse_probe, plan
from track_downloader.cli import build_parser, main
from track_downloader.ytdlp_args import DownloadOptions, build_ytdlp_command

HAS_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None


def wav(bits: int, rate: int, downmix: bool = False) -> Action:
    return Action("wav", extension="wav", bit_depth=bits, sample_rate=rate, downmix=downmix)


class RuleTests(unittest.TestCase):
    def test_universal_formats_have_no_issues(self):
        for probe, ext in [
            (Probe("mp3", sample_rate=44100), ".mp3"),
            (Probe("aac", profile="LC", sample_rate=48000), ".m4a"),
            (Probe("pcm_s16le", sample_rate=44100), ".wav"),
            (Probe("pcm_s24be", sample_rate=48000), ".aiff"),
            (Probe("pcm_s16be", sample_rate=44100, channels=1), ".aif"),
        ]:
            self.assertEqual(check(probe, ext), [], (probe.codec, ext))

    def test_flags_what_older_decks_cannot_load(self):
        self.assertEqual(check(Probe("flac", sample_rate=44100), ".flac"), [Issue("UNSUPPORTED_FORMAT", ".flac")])
        self.assertEqual(check(Probe("alac", sample_rate=44100), ".m4a"), [Issue("UNSUPPORTED_FORMAT", "ALAC")])
        self.assertEqual(check(Probe("opus", sample_rate=48000), ".webm"), [Issue("UNSUPPORTED_FORMAT", ".webm")])
        self.assertEqual(check(Probe("aac", profile="HE-AAC", sample_rate=44100), ".m4a"),
                         [Issue("AAC_PROFILE", "HE-AAC")])
        self.assertEqual(check(Probe("pcm_f32le", sample_rate=44100), ".wav"), [Issue("BIT_DEPTH", "32-bit float")])
        self.assertEqual(check(Probe("pcm_s24le", sample_rate=88200), ".wav"), [Issue("SAMPLE_RATE", "88.2 kHz")])
        self.assertEqual(check(Probe("aac", sample_rate=44100), ".mp3"), [Issue("EXT_MISMATCH", "aac in .mp3")])
        self.assertEqual(check(Probe("pcm_s16le", sample_rate=44100, channels=6), ".wav"),
                         [Issue("UNSUPPORTED_FORMAT", "6 channels")])

    def test_low_rate_mp3_is_a_warning_and_fat32_names_are_info(self):
        self.assertEqual([i.severity for i in check(Probe("mp3", sample_rate=22050), ".mp3")], ["warning"])
        self.assertIsNone(cdj_safe.file_name_issue("Artist - Track ⧸⧸ Remix ＊ [1].m4a"))
        self.assertEqual(cdj_safe.file_name_issue("What?.mp3").severity, "info")

    def test_plan_matches_the_swift_port(self):
        cases = [
            (Probe("aac", profile="LC", sample_rate=44100), ".m4a", Action("keep")),
            (Probe("mp3", sample_rate=22050), ".mp3", Action("keep")),
            (Probe("aac", profile="LC", sample_rate=44100), ".mp3", Action("remux", extension="m4a")),
            (Probe("mp3", sample_rate=44100), ".wav", Action("remux", extension="mp3")),
            (Probe("flac", sample_rate=96000, bits_per_raw_sample=24), ".flac", wav(24, 48000)),
            (Probe("flac", sample_rate=44100, bits_per_raw_sample=16), ".flac", wav(16, 44100)),
            (Probe("flac", sample_rate=44100), ".flac", wav(24, 44100)),
            (Probe("alac", sample_rate=48000, bits_per_raw_sample=24), ".m4a", wav(24, 48000)),
            (Probe("pcm_f32le", sample_rate=44100), ".wav", wav(24, 44100)),
            (Probe("pcm_u8", sample_rate=44100), ".wav", wav(16, 44100)),
            (Probe("pcm_s24le", sample_rate=88200), ".wav", wav(24, 44100)),
            (Probe("pcm_s24le", sample_rate=192000), ".wav", wav(24, 48000)),
            (Probe("pcm_s16le", sample_rate=44100, channels=6), ".wav", wav(16, 44100, downmix=True)),
            (Probe("opus", sample_rate=48000), ".opus", wav(16, 48000)),
            (Probe("aac", profile="HE-AAC", sample_rate=44100), ".mp3", wav(16, 44100)),
        ]
        for probe, ext, expected in cases:
            self.assertEqual(plan(probe, ext), expected, (probe, ext))
        self.assertEqual(plan(None, ".mp3").kind, "cannot_fix")

    def test_ffmpeg_arguments(self):
        flac = Probe("flac", sample_rate=96000, bits_per_raw_sample=24)
        self.assertEqual(
            ffmpeg_args(wav(24, 48000), "/dev/fd/0", "/music/.tmp.wav", flac),
            ["-nostdin", "-v", "error", "-n", "-i", "/dev/fd/0", "-map", "0:a:0", "-map_metadata", "0",
             "-c:a", "pcm_s24le", "-ar", "48000", "/music/.tmp.wav"],
        )
        self.assertEqual(ffmpeg_args(Action("remux", extension="m4a"), "in", "out.m4a", flac)[-5:],
                         ["-c:a", "copy", "-movflags", "+faststart", "out.m4a"])
        opus = Probe("opus", sample_rate=48000, tags_on_audio_stream=True)
        args = ffmpeg_args(wav(16, 48000), "in", "out.wav", opus)
        self.assertEqual(args[args.index("-map_metadata") + 1], "0:s:a:0")

    def test_parse_probe(self):
        probe = parse_probe(textwrap.dedent("""
            {"streams":[{"codec_type":"audio","codec_name":"flac","sample_rate":"96000","channels":2,
                         "bits_per_raw_sample":"24"},
                        {"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}}],
             "format":{"duration":"30.000000","tags":{"title":"Night Drive"}}}
        """))
        self.assertEqual(probe, Probe("flac", sample_rate=96000, channels=2, bits_per_raw_sample=24, duration=30.0))
        self.assertIsNone(parse_probe("{}"))
        self.assertIsNone(parse_probe("not json"))

    def test_verification(self):
        source = Probe("flac", sample_rate=96000, duration=300.0)
        self.assertIsNone(cdj_safe.verification_problem(source, Probe("pcm_s24le", sample_rate=48000, duration=300.05), ".wav"))
        self.assertEqual(cdj_safe.verification_problem(source, None, ".wav"), "the converted file is unreadable")
        self.assertEqual(cdj_safe.verification_problem(source, Probe("pcm_s24le", sample_rate=48000, duration=120.0), ".wav"),
                         "the length changed (300.00s to 120.00s)")


def make_fixture(path: Path, *encode: str, rate: int = 44100, layout: str = "stereo", seconds: float = 2.0) -> None:
    subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi",
         "-i", f"sine=f=440:d={seconds}:r={rate},aformat=channel_layouts={layout}", *encode, str(path)],
        check=True,
    )


def codec_of(path: Path) -> tuple[str, str]:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name,sample_rate",
         "-of", "default=nw=1:nk=1", str(path)],
        capture_output=True, text=True, check=True,
    )
    codec, rate = result.stdout.split()
    return codec, rate


@unittest.skipUnless(HAS_FFMPEG, "ffmpeg/ffprobe not installed")
class MakeCdjSafeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def leftovers(self) -> list[str]:
        return [p.name for p in self.root.iterdir() if p.name.startswith(cdj_safe.TEMPORARY_PREFIX)]

    def test_converts_hi_res_flac_to_24_bit_48k_wav_and_removes_the_flac(self):
        flac = self.root / "Artist - Track [1].flac"
        make_fixture(flac, "-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24", rate=96000)

        outcome = make_cdj_safe(flac, self.root)

        self.assertEqual(outcome.status, "converted")
        self.assertEqual(outcome.path, self.root / "Artist - Track [1].wav")
        self.assertEqual(codec_of(outcome.path), ("pcm_s24le", "48000"))
        self.assertFalse(flac.exists())
        self.assertEqual(self.leftovers(), [])
        self.assertEqual(outcome.summary, "CDJ-safe: converted to 24-bit WAV, 48 kHz")

    def test_rewrites_float_wav_in_place(self):
        path = self.root / "Track.wav"
        make_fixture(path, "-c:a", "pcm_f32le")

        outcome = make_cdj_safe(path, self.root)

        self.assertEqual((outcome.status, outcome.path), ("converted", path))
        self.assertEqual(codec_of(path), ("pcm_s24le", "44100"))

    def test_rewraps_aac_saved_as_mp3_and_keeps_opus_tags_when_converting(self):
        mislabeled = self.root / "Track.mp3"
        make_fixture(mislabeled, "-c:a", "aac", "-b:a", "160k", "-f", "adts")
        opus = self.root / "Opus.opus"
        make_fixture(opus, "-c:a", "libopus", "-metadata", "title=Opus Title", rate=48000)

        rewrapped = make_cdj_safe(mislabeled, self.root)
        converted = make_cdj_safe(opus, self.root)

        self.assertEqual((rewrapped.status, rewrapped.path.name), ("converted", "Track.m4a"))
        self.assertEqual(codec_of(rewrapped.path)[0], "aac")
        self.assertEqual(codec_of(converted.path), ("pcm_s16le", "48000"))
        title = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format_tags=title", "-of",
                                "default=nw=1:nk=1", str(converted.path)], capture_output=True, text=True).stdout
        self.assertEqual(title.strip(), "Opus Title")

    def test_never_overwrites_and_never_follows_symlinks(self):
        flac = self.root / "Track.flac"
        make_fixture(flac, "-c:a", "flac")
        taken = self.root / "Track.wav"
        taken.write_bytes(b"someone else's file")
        with tempfile.TemporaryDirectory() as outside_dir:
            outside = Path(outside_dir) / "outside.flac"
            make_fixture(outside, "-c:a", "flac")
            link = self.root / "Linked.flac"
            link.symlink_to(outside)

            blocked = make_cdj_safe(flac, self.root)
            linked = make_cdj_safe(link, self.root)

            self.assertEqual((blocked.status, blocked.reason), ("left_as_downloaded", "Track.wav already exists"))
            self.assertEqual(taken.read_bytes(), b"someone else's file")
            self.assertTrue(flac.exists())
            self.assertEqual(linked.status, "left_as_downloaded")
            self.assertEqual(sorted(p.name for p in Path(outside_dir).iterdir()), ["outside.flac"])

    def test_leaves_files_every_deck_plays_untouched(self):
        path = self.root / "Track.m4a"
        make_fixture(path, "-c:a", "aac", "-b:a", "160k")
        before = path.read_bytes()

        outcome = make_cdj_safe(path, self.root)

        self.assertEqual((outcome.status, outcome.summary), ("already_safe", "CDJ-safe"))
        self.assertEqual(path.read_bytes(), before)


class CliTests(unittest.TestCase):
    def test_records_saved_paths_only_when_asked(self):
        options = DownloadOptions(output_dir=Path("/tmp/dj-library"))
        self.assertNotIn("--print-to-file", build_ytdlp_command(["https://youtu.be/x"], options))

        record = Path("/tmp/100% sure/saved.txt")
        command = build_ytdlp_command(["https://youtu.be/x"], DownloadOptions(output_dir=Path("/tmp/x"), saved_paths_file=record))
        index = command.index("--print-to-file")
        self.assertEqual(command[index + 1 : index + 3], ["after_move:%(filepath)s", "/tmp/100%% sure/saved.txt"])

    def test_cdj_safe_is_on_by_default(self):
        self.assertTrue(build_parser().parse_args(["https://youtu.be/x"]).cdj_safe)
        self.assertFalse(build_parser().parse_args(["--no-cdj-safe", "https://youtu.be/x"]).cdj_safe)

    @unittest.skipUnless(HAS_FFMPEG and shutil.which("yt-dlp"), "needs yt-dlp, ffmpeg and ffprobe")
    def test_real_ytdlp_keeps_aif_and_upper_case_originals_intact(self):
        # Offline: yt-dlp's generic extractor reads local files standing in for uploaders' originals.
        # Before the extension rules, the .aif became a ~130 kbps MP3 and the .MP3 was lost.
        with tempfile.TemporaryDirectory() as temp_dir:
            workspace = Path(temp_dir)
            originals, library = workspace / "originals", workspace / "library"
            originals.mkdir()
            make_fixture(originals / "bounce.aif", "-c:a", "pcm_s24be")
            make_fixture(originals / "LOUD.MP3", "-c:a", "libmp3lame", "-b:a", "320k", "-f", "mp3")

            for original in sorted(originals.iterdir()):
                options = DownloadOptions(output_dir=library, use_archive=False,
                                          extra_ytdlp_args=["--enable-file-urls", "--no-warnings", "-q"])
                result = subprocess.run(build_ytdlp_command([original.as_uri()], options),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            saved = {p.suffix: codec_of(p)[0] for p in (library / "Generic").iterdir() if p.suffix != ".json"}
            self.assertEqual(saved, {".aiff": "pcm_s24be", ".mp3": "mp3"})

    @unittest.skipUnless(HAS_FFMPEG, "ffmpeg/ffprobe not installed")
    def test_cli_makes_each_saved_file_cdj_safe(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            workspace = Path(temp_dir)
            output_dir = workspace / "library"
            fake_ytdlp = workspace / "yt-dlp"
            # Stands in for yt-dlp: "downloads" a 24/96 FLAC original and records its final path.
            fake_ytdlp.write_text(textwrap.dedent(f"""\
                #!{sys.executable}
                import subprocess, sys
                args = sys.argv[1:]
                out = args[args.index("--paths") + 1] + "/Artist - Original [42].flac"
                subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                                "sine=f=440:d=2:r=96000", "-c:a", "flac", "-sample_fmt", "s32",
                                "-bits_per_raw_sample", "24", out], check=True)
                record = args[args.index("--print-to-file") + 2].replace("%%", "%")
                open(record, "a").write(out + "\\n")
            """))
            fake_ytdlp.chmod(0o755)

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = main(["--yt-dlp-bin", str(fake_ytdlp), "--no-archive", "-o", str(output_dir),
                             "https://soundcloud.com/artist/original"])

            self.assertEqual(code, 0)
            self.assertEqual(sorted(p.name for p in output_dir.iterdir()), ["Artist - Original [42].wav"])
            self.assertEqual(codec_of(output_dir / "Artist - Original [42].wav"), ("pcm_s24le", "48000"))
            self.assertIn("[cdj-safe] Artist - Original [42].wav: CDJ-safe: converted to 24-bit WAV, 48 kHz",
                          stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
