import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "script" / "open_source_guard.py"


def run_git(root: Path, *args: str, input: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(["git", *args], cwd=root, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)


class OpenSourceGuardTests(unittest.TestCase):
    def make_repo(self) -> tempfile.TemporaryDirectory[str]:
        temp = tempfile.TemporaryDirectory()
        root = Path(temp.name)
        run_git(root, "init", "-q")
        run_git(root, "config", "user.email", "test@example.invalid")
        run_git(root, "config", "user.name", "Test")
        return temp

    def guard(self, root: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["python3", str(GUARD), *args], cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_staged_guard_reads_index_blob_not_unstaged_replacement(self):
        with self.make_repo() as name:
            root = Path(name); token = "ghp" + "_abcdefghijklmnopqrstuvwxyz1234567890"
            (root / "notes.txt").write_text(token + "\n", encoding="utf-8")
            run_git(root, "add", "notes.txt")
            (root / "notes.txt").write_text("safe\n", encoding="utf-8")
            result = self.guard(root, "--staged")
            self.assertEqual(result.returncode, 1); self.assertIn("possible-secret: notes.txt", result.stdout); self.assertNotIn(token, result.stdout)

    def test_staged_guard_ignores_unstaged_secret_when_index_blob_is_safe(self):
        with self.make_repo() as name:
            root = Path(name)
            (root / "notes.txt").write_text("safe\n", encoding="utf-8"); run_git(root, "add", "notes.txt")
            (root / "notes.txt").write_text("ghp" + "_abcdefghijklmnopqrstuvwxyz1234567890\n", encoding="utf-8")
            self.assertEqual(self.guard(root, "--staged").returncode, 0)

    def test_staged_deletion_is_not_reported_as_unreadable(self):
        with self.make_repo() as name:
            root = Path(name); (root / ".env").write_text("safe\n", encoding="utf-8")
            run_git(root, "add", ".env"); run_git(root, "commit", "-qm", "base")
            run_git(root, "rm", "-q", ".env")
            self.assertEqual(self.guard(root, "--staged").returncode, 0)

    def test_staged_symlink_and_gitlink_are_rejected_by_mode_without_following_them(self):
        with self.make_repo() as name:
            root = Path(name); (root / "link").symlink_to("missing-target")
            run_git(root, "add", "link")
            run_git(root, "update-index", "--add", "--cacheinfo", "160000," + "1" * 40 + ",submodule")
            result = self.guard(root, "--staged")
            self.assertIn("staged-symlink: link", result.stdout); self.assertIn("staged-gitlink: submodule", result.stdout)

    def test_secret_and_personal_path_signatures_crossing_read_chunks_are_detected(self):
        with self.make_repo() as name:
            root = Path(name); secret = "ghp" + "_abcdefghijklmnopqrstuvwxyz1234567890"; personal = "/" + "Users" + "/private/release"
            (root / "large.txt").write_bytes(b"x" * (64 * 1024 - 6) + b" " + secret.encode() + b"\n" + personal.encode())
            run_git(root, "add", "large.txt")
            result = self.guard(root, "--staged")
            self.assertIn("possible-secret: large.txt", result.stdout); self.assertIn("personal-path: large.txt", result.stdout)
            self.assertNotIn(secret, result.stdout); self.assertNotIn(personal, result.stdout)

    def test_workflow_policy_accepts_pinned_read_only_workflow(self):
        from script.open_source_guard import audit_workflow
        content = b"name: CI\non: [push]\npermissions:\n  contents: read\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@0123456789abcdef0123456789abcdef01234567\n"
        self.assertEqual(audit_workflow(".github/workflows/ci.yml", content), [])

    def test_workflow_policy_fails_closed_on_unsafe_forms(self):
        from script.open_source_guard import audit_workflow
        cases = [b"on: pull_request_target\npermissions: write-all\n", b"permissions:\n  contents: write\n", b"permissions: {contents: read}\n", b"jobs:\n  a:\n    permissions:\n      contents: read\n"]
        for content in cases:
            self.assertTrue(audit_workflow(".github/workflows/ci.yml", content))

    def test_workflow_policy_ignores_commented_trigger_and_rejects_job_overrides(self):
        from script.open_source_guard import audit_workflow
        safe = b"# pull_request_target\non: [push]\npermissions:\n  contents: read\n"
        self.assertEqual(audit_workflow(".github/workflows/ci.yml", safe), [])
        job_override = b"on: [push]\npermissions:\n  contents: read\njobs:\n  test:\n    permissions:\n      contents: read\n"
        rules = {finding.rule for finding in audit_workflow(".github/workflows/ci.yml", job_override)}
        self.assertIn("unsafe-workflow-permissions", rules)

    def test_workflow_policy_accepts_quoted_cron_wildcards(self):
        from script.open_source_guard import audit_workflow
        content = b"on:\n  schedule:\n    - cron: '17 8 1 * *'\npermissions:\n  contents: read\n"
        self.assertEqual(audit_workflow(".github/workflows/ci.yml", content), [])

    def test_workflow_policy_allows_codeql_security_events_only_in_codeql_file(self):
        from script.open_source_guard import audit_workflow
        codeql = b"on: [push]\npermissions:\n  actions: read\n  contents: read\n  security-events: write\n"
        self.assertEqual(audit_workflow(".github/workflows/codeql.yml", codeql), [])
        self.assertTrue(audit_workflow(".github/workflows/ci.yml", codeql))

    def test_workflow_policy_rejects_unpinned_or_unsupported_actions(self):
        from script.open_source_guard import audit_workflow
        prefix = b"on: [push]\npermissions:\n  contents: read\njobs:\n  test:\n    steps:\n"
        for uses in (
            b"actions/checkout@main",
            b"actions/checkout@0123456",
            b"docker://alpine:latest",
            b"evil/action@0123456789abcdef0123456789abcdef01234567",
        ):
            findings = audit_workflow(".github/workflows/ci.yml", prefix + b"      - uses: " + uses + b"\n")
            self.assertIn("unsafe-workflow-action", {finding.rule for finding in findings})
