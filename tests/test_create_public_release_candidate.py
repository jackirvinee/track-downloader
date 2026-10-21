import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout.strip()


class CandidateBuilderTests(unittest.TestCase):
    def repo(self):
        temp = tempfile.TemporaryDirectory(); root = Path(temp.name); git(root, "init", "-q"); git(root, "config", "user.name", "Test"); git(root, "config", "user.email", "test@example.invalid")
        (root / "a file.txt").write_text("committed\n"); (root / "run.sh").write_text("#!/bin/sh\n"); (root / "run.sh").chmod(0o755)
        git(root, "add", "."); git(root, "commit", "-qm", "base")
        return temp

    def test_allowlist_rejects_unsafe_and_duplicate_entries(self):
        from script.create_public_release_candidate import load_allowlist
        with tempfile.TemporaryDirectory() as name:
            path = Path(name) / "list"; path.write_text("good.txt\ngood.txt\n")
            with self.assertRaises(ValueError): load_allowlist(path)
            for bad in ("\n", "/absolute\n", "a/../b\n", "a\\b\n", "*.txt\n", "a]b\n", "a:b\n", "a\x01b\n", ":(glob)x\n"):
                path.write_text(bad)
                with self.assertRaises(ValueError): load_allowlist(path)

    def test_exports_exact_committed_blobs_with_modes_and_manifest(self):
        from script.create_public_release_candidate import build_candidate, resolve_revision, write_sha256_manifest
        with self.repo() as name:
            root = Path(name); (root / "a file.txt").write_text("dirty\n")
            commit = resolve_revision(root, "HEAD"); out = root / "candidate"
            build_candidate(root, commit, out, ("a file.txt", "run.sh")); manifest = write_sha256_manifest(out)
            self.assertEqual((out / "a file.txt").read_text(), "committed\n"); self.assertTrue((out / "run.sh").stat().st_mode & 0o111)
            rows = manifest.read_text().splitlines(); self.assertEqual(len(rows), 2); self.assertNotIn("SHA256SUMS.txt", "\n".join(rows))
            for row in rows:
                digest, path = row.split("  "); self.assertEqual(digest, hashlib.sha256((out / path).read_bytes()).hexdigest())

    def test_rejects_noncommit_missing_symlink_and_existing_destination(self):
        from script.create_public_release_candidate import build_candidate, resolve_public_blobs, resolve_revision
        with self.repo() as name:
            root = Path(name); commit = resolve_revision(root, "HEAD")
            with self.assertRaises(ValueError): resolve_revision(root, "HEAD:a file.txt")
            with self.assertRaises(ValueError): resolve_public_blobs(root, commit, ("missing",))
            out = root / "exists"; out.mkdir()
            with self.assertRaises(FileExistsError): build_candidate(root, commit, out, ("a file.txt",))

    def test_cli_runs_from_a_repository_root(self):
        with self.repo() as name:
            root = Path(name); allowlist = root / "script"; allowlist.mkdir()
            (allowlist / "public_release_paths.txt").write_text("a file.txt\n", encoding="utf-8")
            command = ["python3", str(Path(__file__).resolve().parents[1] / "script/create_public_release_candidate.py"), "--revision", "HEAD", "--output", str(root / "candidate")]
            result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_public_allowlist_excludes_private_hook_tooling(self):
        from script.create_public_release_candidate import load_allowlist, resolve_public_blobs, resolve_revision
        paths = load_allowlist(Path(__file__).resolve().parents[1] / "script/public_release_paths.txt")
        for private in (".githooks/pre-commit", "script/install_git_hooks.sh", "tests/test_git_hooks.py"):
            self.assertNotIn(private, paths)
        for private_prefix in ("docs/superpowers/", ".git/"):
            self.assertFalse(any(path.startswith(private_prefix) for path in paths))
        for public in ("script/open_source_guard.py", "script/create_public_release_candidate.py", "script/run_open_source_release_gate.py"):
            self.assertIn(public, paths)
        root = Path(__file__).resolve().parents[1]
        if not (root / ".git").exists():
            self.skipTest("candidate is intentionally materialized without a Git directory")
        blobs = resolve_public_blobs(root, resolve_revision(root, "HEAD"), paths)
        self.assertEqual(tuple(blob.path for blob in blobs), paths)

    def test_public_allowlist_includes_platform_parity_contract(self):
        from script.create_public_release_candidate import load_allowlist
        paths = load_allowlist(Path(__file__).resolve().parents[1] / "script/public_release_paths.txt")
        for public in ("platform-parity.json", "script/verify_platform_parity.py", "tests/test_platform_parity.py"):
            self.assertIn(public, paths)

    def test_public_allowlist_includes_complete_swift_package_build_surface(self):
        from script.create_public_release_candidate import load_allowlist

        paths = load_allowlist(Path(__file__).resolve().parents[1] / "script/public_release_paths.txt")
        required = (
            "Sources/TrackDownloader/Models/AppearancePreference.swift",
            "Sources/TrackDownloader/Models/SourcePanePresentation.swift",
            "Sources/TrackDownloader/Models/TrackInspectorPresentation.swift",
            "Sources/TrackDownloader/Models/WaveformProjection.swift",
            "Sources/TrackDownloader/Models/WorkspaceStatusPresentation.swift",
            "Sources/TrackDownloader/Services/AudioWaveformLoading.swift",
            "Sources/TrackDownloader/Stores/ChromeQueueStore.swift",
            "Sources/TrackDownloader/Views/ChromeQueueView.swift",
            "Sources/TrackDownloader/Views/DownloadedTracksTable.swift",
            "Sources/TrackDownloader/Views/LibrarySelectionDetailView.swift",
            "Sources/TrackDownloader/Views/WorkspaceStatusBar.swift",
            "Sources/TrackDownloaderChromeCompanion/ChromeCompanionQueue.swift",
            "Sources/TrackDownloaderChromeCompanion/ChromeCompanionRequest.swift",
            "Sources/TrackDownloaderChromeCompanion/NativeMessageHost.swift",
            "Sources/TrackDownloaderChromeHost/main.swift",
            "tests/TrackDownloaderChromeCompanionTests/ChromeCompanionRequestTests.swift",
            "tests/TrackDownloaderChromeCompanionTests/NativeMessageHostTests.swift",
            "tests/TrackDownloaderTests/ChromeQueueStoreTests.swift",
            "tests/TrackDownloaderTests/AppearancePreferenceTests.swift",
            "tests/TrackDownloaderTests/AudioWaveformLoaderTests.swift",
            "tests/TrackDownloaderTests/TrackInspectorPresentationTests.swift",
            "tests/TrackDownloaderTests/SourceResultReentryPolicyTests.swift",
            "tests/TrackDownloaderTests/WaveformProjectionTests.swift",
            "tests/TrackDownloaderTests/WorkspaceStatusPresentationTests.swift",
            "script/install_chrome_companion.sh",
            "chrome-extension/manifest.json",
            "chrome-extension/native-host-manifest.json",
            "chrome-extension/content-logic.js",
            "chrome-extension/content-script.css",
            "chrome-extension/content-script.js",
            "chrome-extension/popup.css",
            "chrome-extension/popup.html",
            "chrome-extension/popup.js",
            "chrome-extension/request.js",
            "chrome-extension/service-worker.js",
            "chrome-extension/tests/manifest.test.mjs",
        )

        self.assertEqual([path for path in required if path not in paths], [])
        self.assertNotIn("Sources/TrackDownloader/Views/InspectorPaneView.swift", paths)

    def test_public_allowlist_covers_every_swift_package_source_and_test(self):
        from script.create_public_release_candidate import load_allowlist

        root = Path(__file__).resolve().parents[1]
        paths = set(load_allowlist(root / "script/public_release_paths.txt"))
        package_paths = {"Package.swift"}
        for directory in (root / "Sources", root / "tests"):
            package_paths.update(
                path.relative_to(root).as_posix()
                for path in directory.rglob("*.swift")
            )

        self.assertEqual(sorted(package_paths - paths), [])

    def test_committed_fixture_candidate_is_public_tree_clean(self):
        from script.create_public_release_candidate import build_candidate, resolve_revision, write_sha256_manifest
        from script.open_source_guard import audit_candidate
        from script.verify_public_release_tree import audit_public_tree
        with self.repo() as name:
            root = Path(name); out = root / "candidate"
            build_candidate(root, resolve_revision(root, "HEAD"), out, ("a file.txt", "run.sh")); write_sha256_manifest(out)
            self.assertEqual(audit_candidate(out), []); self.assertEqual(audit_public_tree(out), [])
