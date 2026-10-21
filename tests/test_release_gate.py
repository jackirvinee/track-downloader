import os
import subprocess
import shutil
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def git(root: Path, *args: str, input: bytes | None = None) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        input=input,
        text=input is None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return result.stdout.strip() if isinstance(result.stdout, str) else result.stdout.decode().strip()


def clone_source(destination: Path) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT, destination, ignore=shutil.ignore_patterns(".git"))
    git(destination, "init", "-q")
    git(destination, "config", "user.name", "Guardrail Tests")
    git(destination, "config", "user.email", "guardrail-tests@example.invalid")
    git(destination, "add", ".")
    git(destination, "commit", "-qm", "fixture base")
    git(destination, "branch", "-M", "test-main")
    return destination


class ReleaseGateTests(unittest.TestCase):
    def test_parse_pre_push_updates_accepts_branches_and_skips_deletions(self):
        from script.run_open_source_release_gate import parse_pre_push_updates
        zero = "0" * 40; one = "1" * 40
        updates = parse_pre_push_updates(f"refs/heads/main {one} refs/heads/main {zero}\nrefs/heads/old {zero} refs/heads/old {one}\n".encode())
        self.assertEqual(len(updates), 1); self.assertEqual(updates[0].local_oid, one)

    def test_parse_pre_push_updates_rejects_tags_and_malformed_rows(self):
        from script.run_open_source_release_gate import parse_pre_push_updates
        with self.assertRaises(ValueError): parse_pre_push_updates(b"x\n")
        with self.assertRaises(ValueError): parse_pre_push_updates(("refs/tags/v1 " + "1" * 40 + " refs/tags/v1 " + "0" * 40 + "\n").encode())

    def test_introduced_commits_cover_intermediate_history_and_remote_tracking_refs(self):
        from script.run_open_source_release_gate import RefUpdate, introduced_commits

        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            git(root, "init", "-q")
            git(root, "config", "user.name", "Guardrail Tests")
            git(root, "config", "user.email", "guardrail-tests@example.invalid")
            (root / "tracked.txt").write_text("base\n")
            git(root, "add", ".")
            git(root, "commit", "-qm", "base")
            base = git(root, "rev-parse", "HEAD")
            (root / "tracked.txt").write_text("one\n")
            git(root, "commit", "-qam", "one")
            one = git(root, "rev-parse", "HEAD")
            (root / "tracked.txt").write_text("two\n")
            git(root, "commit", "-qam", "two")
            two = git(root, "rev-parse", "HEAD")
            git(root, "update-ref", "refs/remotes/origin/main", base)

            update = RefUpdate("refs/heads/topic", two, "refs/heads/topic", "0" * 40)
            self.assertEqual(introduced_commits(root, update, "origin"), (one, two))

    def test_static_gate_uses_allowlist_and_sources_from_requested_nonchecked_out_revision(self):
        if os.environ.get("TRACK_DOWNLOADER_RELEASE_GATE_RUN"):
            self.skipTest("revision isolation is exercised by the focused release-gate suite")
        from script.run_open_source_release_gate import run_release_gate

        with tempfile.TemporaryDirectory() as name:
            root = clone_source(Path(name) / "repo")
            base = git(root, "rev-parse", "HEAD")
            git(root, "checkout", "-q", "-b", "target")
            (root / "tests" / "test_target_revision.py").write_text(
                "import unittest\n\nclass TargetRevisionTest(unittest.TestCase):\n"
                "    def test_target_revision_is_executed(self):\n"
                "        self.fail('target revision test ran')\n"
            )
            allowlist = root / "script/public_release_paths.txt"
            allowlist.write_text(allowlist.read_text() + "tests/test_target_revision.py\n")
            git(root, "add", "tests/test_target_revision.py", "script/public_release_paths.txt")
            git(root, "commit", "-qm", "target revision")
            target = git(root, "rev-parse", "HEAD")
            git(root, "checkout", "-q", "test-main")
            # Dirty checkout contents must not replace the committed target source.
            (root / "tests" / "test_target_revision.py").write_text(
                "import unittest\n\nclass TargetRevisionTest(unittest.TestCase):\n"
                "    def test_target_revision_is_executed(self):\n        pass\n"
            )
            allowlist.write_text(allowlist.read_text().replace("tests/test_target_revision.py\n", ""))
            self.assertEqual(run_release_gate(root, target), 1)
            self.assertEqual(git(root, "rev-parse", "HEAD"), base)

    def test_pre_push_gate_rejects_secret_then_delete_range_in_real_bare_remote(self):
        if os.environ.get("TRACK_DOWNLOADER_RELEASE_GATE_RUN"):
            self.skipTest("range integration is exercised by the focused release-gate suite")
        from script.run_open_source_release_gate import ZERO, parse_pre_push_updates

        with tempfile.TemporaryDirectory() as name:
            parent = Path(name)
            root = clone_source(parent / "repo")
            bare = parent / "remote.git"
            git(parent, "init", "--bare", "-q", str(bare))
            git(root, "remote", "add", "test", str(bare))
            base = git(root, "rev-parse", "HEAD")
            token = "ghp" + "_" + "abcdefghijklmnopqrstuvwxyz1234567890"
            (root / "README.md").write_text(token + "\n")
            git(root, "commit", "--no-verify", "-qam", "intermediate secret")
            intermediate = git(root, "rev-parse", "HEAD")
            with (root / "README.md").open("wb") as handle:
                subprocess.run(["git", "show", f"{base}:README.md"], cwd=root, stdout=handle, check=True)
            git(root, "commit", "-qam", "delete secret")
            tip = git(root, "rev-parse", "HEAD")
            update = f"refs/heads/main {tip} refs/heads/main {ZERO}\n".encode()
            parsed = parse_pre_push_updates(update)
            self.assertEqual(parsed[0].local_oid, tip)
            self.assertNotEqual(intermediate, tip)

            result = subprocess.run(
                ["python3", "script/run_open_source_release_gate.py", "--pre-push", "test"],
                cwd=root,
                input=update,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(token.encode(), result.stdout + result.stderr)
