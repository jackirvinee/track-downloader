import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "script/verify_platform_parity.py"
ZERO_SHA = "0" * 40


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()


def valid_catalog() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "principles": {
            "nativeUIs": "separate",
            "translation": "manual-only",
            "parityMechanism": "capability-contract",
        },
        "capabilities": [
            {
                "id": "single-link-download",
                "description": "Run one local download from a supported HTTPS link.",
                "macos": {
                    "status": "implemented",
                    "verification": "source-tested",
                    "evidence": ["Sources/TrackDownloader/Download.swift"],
                },
                "windows": {
                    "status": "planned",
                    "verification": "not-tested",
                    "evidence": [],
                },
            }
        ],
    }


class PlatformParityTests(unittest.TestCase):
    def make_repo(self) -> tempfile.TemporaryDirectory[str]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        git(root, "init", "-q")
        git(root, "config", "user.name", "Test")
        git(root, "config", "user.email", "test@example.invalid")
        (root / "Sources/TrackDownloader").mkdir(parents=True)
        (root / "Sources/TrackDownloaderCore").mkdir(parents=True)
        (root / "windows").mkdir()
        (root / "Sources/TrackDownloader/Download.swift").write_text("base\n", encoding="utf-8")
        (root / "Sources/TrackDownloaderCore/Core.swift").write_text("base\n", encoding="utf-8")
        (root / "windows/App.cs").write_text("base\n", encoding="utf-8")
        self.write_catalog(root)
        git(root, "add", ".")
        git(root, "commit", "-qm", "base")
        return temporary

    def write_catalog(self, root: Path, catalog: dict[str, object] | None = None) -> None:
        (root / "platform-parity.json").write_text(
            json.dumps(catalog or valid_catalog(), indent=2) + "\n",
            encoding="utf-8",
        )

    def verify(self, root: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(VERIFIER), *args],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_accepts_valid_catalog(self) -> None:
        with self.make_repo() as name:
            result = self.verify(Path(name))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "platform parity: ok\n")

    def test_rejects_duplicate_capability_ids(self) -> None:
        with self.make_repo() as name:
            root = Path(name)
            catalog = valid_catalog()
            catalog["capabilities"] = [catalog["capabilities"][0], catalog["capabilities"][0]]
            self.write_catalog(root, catalog)

            result = self.verify(root)

        self.assertEqual(result.returncode, 1)
        self.assertIn("duplicate capability id: single-link-download", result.stdout)

    def test_rejects_unknown_states_and_changed_principles(self) -> None:
        with self.make_repo() as name:
            root = Path(name)
            catalog = valid_catalog()
            catalog["principles"]["translation"] = "automatic"
            catalog["capabilities"][0]["windows"]["status"] = "done"
            self.write_catalog(root, catalog)

            result = self.verify(root)

        self.assertEqual(result.returncode, 1)
        self.assertIn("principles.translation must equal manual-only", result.stdout)
        self.assertIn("single-link-download.windows.status is invalid: done", result.stdout)

    def test_requires_evidence_for_implemented_capabilities(self) -> None:
        with self.make_repo() as name:
            root = Path(name)
            catalog = valid_catalog()
            catalog["capabilities"][0]["macos"]["evidence"] = []
            self.write_catalog(root, catalog)

            result = self.verify(root)

        self.assertEqual(result.returncode, 1)
        self.assertIn("single-link-download.macos requires evidence", result.stdout)

    def test_requires_catalog_change_for_track_downloader_source(self) -> None:
        with self.make_repo() as name:
            root = Path(name)
            base = git(root, "rev-parse", "HEAD")
            (root / "Sources/TrackDownloader/Download.swift").write_text("changed\n", encoding="utf-8")
            git(root, "add", ".")
            git(root, "commit", "-qm", "change app")

            result = self.verify(root, "--base", base, "--head", "HEAD")

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "macOS source changed without platform-parity.json changing: Sources/TrackDownloader/Download.swift",
            result.stdout,
        )

    def test_requires_catalog_change_for_track_downloader_core(self) -> None:
        with self.make_repo() as name:
            root = Path(name)
            base = git(root, "rev-parse", "HEAD")
            (root / "Sources/TrackDownloaderCore/Core.swift").write_text("changed\n", encoding="utf-8")
            git(root, "add", ".")
            git(root, "commit", "-qm", "change core")

            result = self.verify(root, "--base", base, "--head", "HEAD")

        self.assertEqual(result.returncode, 1)
        self.assertIn("Sources/TrackDownloaderCore/Core.swift", result.stdout)

    def test_accepts_mac_source_change_with_catalog_change(self) -> None:
        with self.make_repo() as name:
            root = Path(name)
            base = git(root, "rev-parse", "HEAD")
            (root / "Sources/TrackDownloader/Download.swift").write_text("changed\n", encoding="utf-8")
            catalog = valid_catalog()
            catalog["capabilities"][0]["description"] = "Run one changed local download."
            self.write_catalog(root, catalog)
            git(root, "add", ".")
            git(root, "commit", "-qm", "change app and parity")

            result = self.verify(root, "--base", base, "--head", "HEAD")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_does_not_require_catalog_change_for_windows_only_change(self) -> None:
        with self.make_repo() as name:
            root = Path(name)
            base = git(root, "rev-parse", "HEAD")
            (root / "windows/App.cs").write_text("changed\n", encoding="utf-8")
            git(root, "add", ".")
            git(root, "commit", "-qm", "change windows")

            result = self.verify(root, "--base", base, "--head", "HEAD")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_handles_zero_base_for_initial_push(self) -> None:
        with self.make_repo() as name:
            root = Path(name)
            result = self.verify(root, "--base", ZERO_SHA, "--head", "HEAD")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
