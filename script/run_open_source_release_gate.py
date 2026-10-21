#!/usr/bin/env python3
"""Run release checks against immutable Git revisions and introduced ranges."""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

try:
    from script.create_public_release_candidate import (
        build_candidate,
        load_allowlist_bytes,
        resolve_revision,
        write_sha256_manifest,
    )
    from script.open_source_guard import audit_candidate
    from script.verify_public_release_tree import audit_public_tree
except ModuleNotFoundError:
    from create_public_release_candidate import (  # type: ignore
        build_candidate,
        load_allowlist_bytes,
        resolve_revision,
        write_sha256_manifest,
    )
    from open_source_guard import audit_candidate  # type: ignore
    from verify_public_release_tree import audit_public_tree  # type: ignore


ZERO = "0" * 40
OID_RE = re.compile(r"[0-9a-f]{40}")
BRANCH_RE = re.compile(r"refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]")


@dataclass(frozen=True)
class RefUpdate:
    local_ref: str
    local_oid: str
    remote_ref: str
    remote_oid: str


def _git_bytes(repo_root: Path, args: list[str]) -> bytes:
    result = subprocess.run(
        ["git", *args],
        cwd=repo_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return result.stdout


def _git_text(repo_root: Path, args: list[str]) -> str:
    return _git_bytes(repo_root, args).decode("utf-8", "strict")


def _valid_branch_ref(ref: str) -> bool:
    return bool(
        BRANCH_RE.fullmatch(ref)
        and ".." not in ref
        and "@{" not in ref
        and not ref.endswith((".", "/"))
        and "//" not in ref
    )


def parse_pre_push_updates(data: bytes) -> tuple[RefUpdate, ...]:
    updates: list[RefUpdate] = []
    for row in data.splitlines():
        try:
            fields = row.decode("ascii", "strict").split()
        except UnicodeDecodeError as exc:
            raise ValueError("malformed-ref-update") from exc
        if len(fields) != 4:
            raise ValueError("malformed-ref-update")
        local_ref, local_oid, remote_ref, remote_oid = fields
        if not all(OID_RE.fullmatch(oid) for oid in (local_oid, remote_oid)):
            raise ValueError("malformed-ref-update")
        if not (_valid_branch_ref(local_ref) and _valid_branch_ref(remote_ref)):
            raise ValueError("unsupported-ref")
        if local_oid == ZERO:
            continue
        updates.append(RefUpdate(local_ref, local_oid, remote_ref, remote_oid))
    return tuple(updates)


def introduced_commits(repo_root: Path, update: RefUpdate, remote_name: str) -> tuple[str, ...]:
    excludes: list[str] = []
    if update.remote_oid != ZERO:
        excludes.append("^" + update.remote_oid)
    else:
        remote_refs = _git_text(
            repo_root,
            ["for-each-ref", "--format=%(objectname)", f"refs/remotes/{remote_name}"],
        ).splitlines()
        excludes.extend("^" + oid for oid in remote_refs if OID_RE.fullmatch(oid))
    commits = _git_text(repo_root, ["rev-list", "--reverse", update.local_oid, *excludes]).splitlines()
    if not all(OID_RE.fullmatch(commit) for commit in commits):
        raise ValueError("invalid-introduced-commit")
    return tuple(commits)


def _safe_materialized_path(path: str) -> bool:
    return bool(path) and not path.startswith("/") and all(
        part not in {"", ".", ".."} for part in path.split("/")
    ) and not any(char in path for char in ("\\", "\x00", "\r", "\n"))


def _write_blob(repo_root: Path, oid: str, destination: Path, executable: bool) -> None:
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(destination, flags, 0o755 if executable else 0o644)
    try:
        process = subprocess.Popen(
            ["git", "cat-file", "blob", oid],
            cwd=repo_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        assert process.stdout is not None
        with os.fdopen(fd, "wb") as output:
            while chunk := process.stdout.read(64 * 1024):
                output.write(chunk)
        process.stdout.close()
        if process.wait() != 0:
            raise ValueError("unreadable blob")
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        raise


def materialize_full_tree(repo_root: Path, commit_oid: str, destination: Path) -> Path:
    rows = [row for row in _git_bytes(repo_root, ["ls-tree", "-r", "-z", "--full-tree", commit_oid]).split(b"\0") if row]
    destination.mkdir(mode=0o755, exist_ok=False)
    for row in rows:
        try:
            metadata, raw_path = row.split(b"\t", 1)
            mode, kind, oid = metadata.decode("ascii").split()
            path = raw_path.decode("utf-8", "strict")
        except (ValueError, UnicodeDecodeError) as exc:
            raise ValueError("invalid full-tree entry") from exc
        if not _safe_materialized_path(path) or kind != "blob" or mode not in {"100644", "100755"}:
            raise ValueError("full tree contains non-regular entry")
        target = destination.joinpath(*path.split("/"))
        target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        _write_blob(repo_root, oid, target, mode == "100755")
    return destination


def _allowlist_for_commit(repo_root: Path, commit_oid: str) -> tuple[str, ...]:
    return load_allowlist_bytes(_git_bytes(repo_root, ["show", f"{commit_oid}:script/public_release_paths.txt"]))


def _prepare_revision(repo_root: Path, commit_oid: str, temp_root: Path) -> tuple[Path, Path]:
    full_tree = materialize_full_tree(repo_root, commit_oid, temp_root / "full-tree")
    candidate = temp_root / "candidate"
    paths = _allowlist_for_commit(repo_root, commit_oid)
    build_candidate(repo_root, commit_oid, candidate, paths)
    findings = audit_candidate(candidate)
    if findings:
        summary = ", ".join(f"{finding.rule}:{finding.path}" for finding in findings)
        raise RuntimeError("candidate hygiene failure: " + summary)
    public_findings = audit_public_tree(candidate)
    if public_findings:
        summary = ", ".join(f"{finding.kind}:{finding.path}" for finding in public_findings)
        raise RuntimeError("public tree verification failure: " + summary)
    write_sha256_manifest(candidate)
    return full_tree, candidate


def run_static_tree_gate(repo_root: Path, commit_oid: str) -> None:
    with tempfile.TemporaryDirectory(prefix="track-downloader-gate-") as name:
        _prepare_revision(repo_root, commit_oid, Path(name))


def _run_command(command: list[str], cwd: Path, env: dict[str, str]) -> None:
    result = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError("release test command failed: " + command[0])


def _run_revision_tests(full_tree: Path, candidate: Path, temp_root: Path) -> None:
    python_root = temp_root / "python"
    swift_scratch = temp_root / "swift-scratch"
    clang_cache = temp_root / "clang-cache"
    swiftpm_cache = temp_root / "swiftpm-cache"
    for directory in (python_root, swift_scratch, clang_cache, swiftpm_cache):
        directory.mkdir(mode=0o700)
    env = os.environ.copy()
    env.update(
        {
            "TMPDIR": str(python_root),
            "PYTHONDONTWRITEBYTECODE": "1",
            "CLANG_MODULE_CACHE_PATH": str(clang_cache),
            "SWIFTPM_MODULECACHE_OVERRIDE": str(clang_cache),
            "SWIFTPM_CUSTOM_CACHE_PATH": str(swiftpm_cache),
            "TRACK_DOWNLOADER_RELEASE_GATE_RUN": "1",
        }
    )
    if (full_tree / "tests" / "test_git_hooks.py").is_file():
        _run_command(["python3", "-m", "unittest", "tests.test_git_hooks"], full_tree, env)
    if (candidate / "script" / "verify_platform_parity.py").is_file():
        _run_command(["python3", "script/verify_platform_parity.py"], candidate, env)
    _run_command(["python3", "-m", "unittest"], candidate, env)
    if (candidate / "Package.swift").is_file():
        _run_command(
            ["swift", "test", "--disable-sandbox", "--scratch-path", str(swift_scratch)],
            candidate,
            env,
        )


def run_release_gate(repo_root: Path, revision: str) -> int:
    try:
        commit_oid = resolve_revision(repo_root, revision)
        with tempfile.TemporaryDirectory(prefix="track-downloader-gate-") as name:
            temp_root = Path(name)
            full_tree, candidate = _prepare_revision(repo_root, commit_oid, temp_root)
            _run_revision_tests(full_tree, candidate, temp_root)
        return 0
    except (OSError, UnicodeError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"open-source gate: {exc}", file=sys.stderr)
        return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--revision")
    group.add_argument("--pre-push", metavar="REMOTE")
    args = parser.parse_args()
    repo_root = Path.cwd()
    if args.revision:
        return run_release_gate(repo_root, args.revision)
    try:
        updates = parse_pre_push_updates(sys.stdin.buffer.read())
        for update in updates:
            for commit_oid in introduced_commits(repo_root, update, args.pre_push):
                run_static_tree_gate(repo_root, commit_oid)
        seen: set[str] = set()
        for update in updates:
            if update.local_oid in seen:
                continue
            seen.add(update.local_oid)
            if run_release_gate(repo_root, update.local_oid):
                return 1
        return 0
    except (OSError, UnicodeError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"open-source gate: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
