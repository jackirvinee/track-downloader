#!/usr/bin/env python3
"""Export a reviewed commit's exact allowlisted blobs without archive extraction."""
from __future__ import annotations

import argparse, hashlib, os, re, stat, subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

try:
    from script.open_source_guard import audit_candidate
except ModuleNotFoundError:
    from open_source_guard import audit_candidate

@dataclass(frozen=True)
class PublicBlob:
    path: str
    oid: str
    executable: bool

def _git(root: Path, args: list[str]) -> bytes:
    try: return subprocess.run(["git", *args], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout
    except subprocess.CalledProcessError as exc: raise ValueError("invalid Git object") from exc

def _safe(path: str) -> bool:
    return bool(path) and not path.startswith("/") and not any(
        ord(char) < 0x20 or ord(char) == 0x7F or char in "\\\r\n\x00*?[]{}:"
        for char in path
    ) and all(p not in {"", ".", ".."} for p in path.split("/"))

def load_allowlist_bytes(raw: bytes) -> tuple[str, ...]:
    if not raw or not raw.endswith(b"\n"): raise ValueError("allowlist must contain newline-terminated paths")
    try: entries = raw.decode("utf-8", "strict").splitlines()
    except UnicodeDecodeError as exc: raise ValueError("allowlist is not UTF-8") from exc
    if not all(_safe(entry) for entry in entries) or len(entries) != len(set(entries)): raise ValueError("invalid allowlist path")
    return tuple(entries)

def load_allowlist(path: Path) -> tuple[str, ...]:
    return load_allowlist_bytes(path.read_bytes())

def resolve_revision(repo_root: Path, revision: str) -> str:
    if not revision or "\x00" in revision: raise ValueError("invalid revision")
    oid = _git(repo_root, ["rev-parse", "--verify", revision + "^{commit}"]).decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", oid): raise ValueError("invalid commit")
    return oid

def resolve_public_blobs(repo_root: Path, commit_oid: str, paths: Sequence[str]) -> tuple[PublicBlob, ...]:
    result: list[PublicBlob] = []
    for path in paths:
        if not _safe(path): raise ValueError("invalid path")
        raw = _git(repo_root, ["ls-tree", "-z", "--full-tree", commit_oid, "--", path])
        rows = [row for row in raw.split(b"\0") if row]
        if len(rows) != 1: raise ValueError("allowlisted path missing or nonliteral")
        meta, actual = rows[0].split(b"\t", 1); mode, kind, oid = meta.decode("ascii").split()
        if actual.decode("utf-8", "strict") != path or kind != "blob" or mode not in {"100644", "100755"}: raise ValueError("allowlisted path is not a regular blob")
        result.append(PublicBlob(path, oid, mode == "100755"))
    return tuple(result)

def _write_blob(repo_root: Path, oid: str, destination: Path, executable: bool) -> None:
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
    if hasattr(os, "O_NOFOLLOW"): flags |= os.O_NOFOLLOW
    fd = os.open(destination, flags, 0o755 if executable else 0o644)
    try:
        proc = subprocess.Popen(["git", "cat-file", "blob", oid], cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        assert proc.stdout is not None
        with os.fdopen(fd, "wb") as out:
            while chunk := proc.stdout.read(64 * 1024): out.write(chunk)
        proc.stdout.close()
        if proc.wait() != 0: raise ValueError("unreadable blob")
    except BaseException:
        try: os.close(fd)
        except OSError: pass
        raise

def build_candidate(repo_root: Path, commit_oid: str, destination: Path, paths: Sequence[str]) -> Path:
    blobs = resolve_public_blobs(repo_root, commit_oid, paths)
    destination.mkdir(mode=0o755, exist_ok=False)
    for blob in blobs:
        target = destination.joinpath(*blob.path.split("/")); target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        _write_blob(repo_root, blob.oid, target, blob.executable)
    return destination

def write_sha256_manifest(candidate: Path) -> Path:
    rows: list[tuple[str, str]] = []
    for root, dirs, files in os.walk(candidate, followlinks=False):
        dirs[:] = sorted(dirs)
        for name in sorted(files):
            path = Path(root) / name; rel = path.relative_to(candidate).as_posix()
            if rel == "SHA256SUMS.txt": continue
            st = path.lstat()
            if not stat.S_ISREG(st.st_mode) or path.is_symlink() or not _safe(rel): raise ValueError("candidate contains unsafe entry")
            digest = hashlib.sha256()
            with path.open("rb") as handle:
                while chunk := handle.read(64 * 1024): digest.update(chunk)
            rows.append((rel, digest.hexdigest()))
    manifest = candidate / "SHA256SUMS.txt"
    with manifest.open("x", encoding="ascii", newline="\n") as handle:
        for path, digest in sorted(rows): handle.write(f"{digest}  {path}\n")
    return manifest

def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--revision", required=True); parser.add_argument("--output", required=True, type=Path); args = parser.parse_args()
    root = Path.cwd(); commit = resolve_revision(root, args.revision); paths = load_allowlist(root / "script/public_release_paths.txt")
    candidate = build_candidate(root, commit, args.output, paths); findings = audit_candidate(candidate)
    if findings:
        for finding in findings: print(f"open-source guard: {finding.rule}: {finding.path}")
        return 1
    write_sha256_manifest(candidate); return 0

if __name__ == "__main__": raise SystemExit(main())
