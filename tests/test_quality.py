import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from track_downloader.quality import (
    AUDIO_EXTENSIONS,
    classify_kbps,
    find_newest_audio_file,
    inspect_audio_quality,
    parse_ffprobe_audio_quality,
)


class QualityTests(unittest.TestCase):
    def test_parse_ffprobe_audio_quality_prefers_stream_bit_rate(self):
        payload = {
            "streams": [
                {
                    "codec_type": "audio",
                    "codec_name": "opus",
                    "bit_rate": "160000",
                    "sample_rate": "48000",
                }
            ],
            "format": {"bit_rate": "170000"},
        }

        quality = parse_ffprobe_audio_quality(json.dumps(payload), Path("/tmp/track.opus"))

        self.assertEqual(quality.kbps, 160)
        self.assertEqual(quality.codec, "opus")
        self.assertEqual(quality.sample_rate_hz, 48000)
        self.assertEqual(quality.verdict, "good")

    def test_parse_ffprobe_audio_quality_falls_back_to_format_bit_rate(self):
        payload = {
            "streams": [{"codec_type": "audio", "codec_name": "aac", "sample_rate": "44100"}],
            "format": {"bit_rate": "128050"},
        }

        quality = parse_ffprobe_audio_quality(json.dumps(payload), Path("/tmp/track.m4a"))

        self.assertEqual(quality.kbps, 128)
        self.assertEqual(quality.codec, "aac")
        self.assertEqual(quality.verdict, "borderline")

    def test_classify_kbps_marks_64_as_low_quality(self):
        self.assertEqual(classify_kbps(64), "low")
        self.assertEqual(classify_kbps(128), "borderline")
        self.assertEqual(classify_kbps(160), "good")
        self.assertEqual(classify_kbps(256), "excellent")
        self.assertEqual(classify_kbps(None), "unknown")

    def test_find_newest_audio_file_ignores_metadata_and_old_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            old_audio = root / "old.opus"
            metadata = root / "track.info.json"
            new_audio = root / "nested" / "track.m4a"
            new_audio.parent.mkdir()
            old_audio.write_text("old")
            metadata.write_text("{}")
            new_audio.write_text("new")
            old_time = 1000
            new_time = 3000
            old_audio.touch()
            metadata.touch()
            new_audio.touch()
            import os

            os.utime(old_audio, (old_time, old_time))
            os.utime(metadata, (new_time + 1, new_time + 1))
            os.utime(new_audio, (new_time, new_time))

            self.assertEqual(find_newest_audio_file(root, since=2000), new_audio)

    def test_inspect_audio_quality_reads_from_a_supplied_open_file(self):
        payload = json.dumps(
            {"streams": [{"codec_type": "audio", "codec_name": "opus", "bit_rate": "160000"}]}
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            audio_file = Path(temp_dir) / "track.opus"
            audio_file.write_bytes(b"pinned-audio")
            with audio_file.open("rb") as standard_input, patch(
                "track_downloader.quality.subprocess.run",
                return_value=subprocess.CompletedProcess([], 0, stdout=payload),
            ) as run:
                quality = inspect_audio_quality(audio_file, standard_input=standard_input)

        command = run.call_args.args[0]
        self.assertEqual(command[-1], "pipe:0")
        self.assertIs(run.call_args.kwargs["stdin"], standard_input)
        self.assertEqual(quality.kbps, 160)

    def test_audio_extensions_include_common_ytdlp_audio_outputs(self):
        self.assertIn(".opus", AUDIO_EXTENSIONS)
        self.assertIn(".m4a", AUDIO_EXTENSIONS)
        self.assertIn(".mp3", AUDIO_EXTENSIONS)


if __name__ == "__main__":
    unittest.main()
