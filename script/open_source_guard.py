#!/usr/bin/env python3
"""Fail-closed release hygiene checks for staged blobs and candidates."""
from __future__ import annotations

import argparse
import os
import re
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path

MAX_PUBLIC_FILE_BYTES = 10 * 1024 * 1024
SCAN_CHUNK_BYTES = 64 * 1024
_SECRET = re.compile(rb"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|\b(?:gh[opusr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|sk_live_[A-Za-z0-9]{16,}|xox[baprs]-[A-Za-z0-9-]{10,})\b")
_PERSONAL = re.compile(rb"(?:/Users/|/home/)[A-Za-z0-9._-]+/|[A-Za-z]:\\Users\\[^\\\r\n]+\\")
_BAD_NAMES = {".build", ".swiftpm", "__pycache__", "_CodeSignature"}
_MEDIA = {".aac", ".aiff", ".alac", ".flac", ".m4a", ".mp3", ".oga", ".ogg", ".opus", ".wav", ".webm", ".zip", ".tar", ".gz", ".dmg"}

@dataclass(frozen=True, order=True)
class Finding:
    rule: str
    path: str

@dataclass(frozen=True)
class IndexEntry:
    status: str
    mode: str
    oid: str
    path: str

def _git(repo: Path, args: list[str], data: bytes | None = None) -> bytes:
    return subprocess.run(["git", *args], cwd=repo, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout

def _valid_path(path: str) -> bool:
    return bool(path) and not path.startswith("/") and "\\" not in path and "\x00" not in path and not any(c in path for c in "\r\n") and all(p not in {"", ".", ".."} for p in path.split("/"))

def read_staged_entries(repo_root: Path) -> list[IndexEntry]:
    raw = _git(repo_root, ["diff", "--cached", "--raw", "-z", "--no-renames"])
    entries: list[IndexEntry] = []
    records = raw.split(b"\0")
    for index in range(0, len(records) - 1, 2):
        record, path = records[index], records[index + 1]
        if not record:
            continue
        try:
            fields = record.decode("ascii").split()
            mode, oid, status = fields[1], fields[3], fields[4]
            entries.append(IndexEntry(status, mode, oid, path.decode("utf-8", "surrogateescape")))
        except (ValueError, UnicodeDecodeError):
            entries.append(IndexEntry("?", "", "", ""))
    return entries

def _scan_stream(stream, path: str, size: int | None = None) -> list[Finding]:
    if size is not None and size > MAX_PUBLIC_FILE_BYTES: return [Finding("large-file", path)]
    found: set[str] = set(); tail = b""
    while True:
        chunk = stream.read(SCAN_CHUNK_BYTES)
        if not chunk: break
        combined = tail + chunk
        if _SECRET.search(combined): found.add("possible-secret")
        if _PERSONAL.search(combined): found.add("personal-path")
        tail = combined[-512:]
    return [Finding(rule, path) for rule in sorted(found)]

def _path_findings(path: str, candidate: bool = False) -> list[Finding]:
    if not _valid_path(path): return [Finding("invalid-path", path or "<invalid>")]
    parts = path.split("/"); name = parts[-1].lower()
    if candidate and len(parts) >= 2 and parts[:2] == ["docs", "superpowers"]: return [Finding("internal-path", path)]
    if name == ".env" or (name.startswith(".env.") and name != ".env.example"): return [Finding("private-runtime-data", path)]
    if name.endswith((".log", ".sqlite", ".db", ".info.json")) or Path(name).suffix in _MEDIA: return [Finding("private-runtime-data", path)]
    if any(part in _BAD_NAMES for part in parts) or ("Contents" in parts and "MacOS" in parts): return [Finding("generated-artifact", path)]
    return []

def audit_staged_index(repo_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for entry in read_staged_entries(repo_root):
        if entry.status.startswith("D"): continue
        findings += _path_findings(entry.path)
        if entry.mode == "120000": findings.append(Finding("staged-symlink", entry.path)); continue
        if entry.mode == "160000": findings.append(Finding("staged-gitlink", entry.path)); continue
        if entry.mode not in {"100644", "100755"}: findings.append(Finding("unsupported-mode", entry.path)); continue
        if entry.path.startswith("docs/superpowers/"): continue
        try:
            proc = subprocess.Popen(["git", "cat-file", "blob", entry.oid], cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            assert proc.stdout is not None
            findings += _scan_stream(proc.stdout, entry.path)
            if proc.wait() != 0: findings.append(Finding("unreadable", entry.path))
        except OSError: findings.append(Finding("unreadable", entry.path))
    return sorted(set(findings))

def _strip_comments(line: str) -> str:
    quote = None; escaped = False
    for i, char in enumerate(line):
        if escaped: escaped = False; continue
        if char == "\\" and quote == '"': escaped = True; continue
        if char in "'\"": quote = None if quote == char else (char if quote is None else quote)
        elif char == "#" and quote is None: return line[:i]
    return line

def audit_workflow(path: str, content: bytes) -> list[Finding]:
    try: text = content.decode("utf-8", "strict")
    except UnicodeDecodeError: return [Finding("unsupported-workflow-syntax", path)]
    findings: set[str] = set(); top_permissions = None; in_jobs = False; codeql = path == ".github/workflows/codeql.yml"
    for raw in text.splitlines():
        syntax = re.sub(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", "", raw)
        if "\t" in raw or "<<:" in syntax or re.search(r"(?:^|[\s:])[&*][A-Za-z_]", syntax): findings.add("unsupported-workflow-syntax")
        line = _strip_comments(raw)
        if not line.strip(): continue
        indent = len(line) - len(line.lstrip(" ")); stripped = line.strip()
        if stripped.startswith("on:") and "pull_request_target" in stripped: findings.add("unsafe-workflow-trigger")
        if "pull_request_target" in stripped: findings.add("unsafe-workflow-trigger")
        if stripped.startswith("jobs:"): in_jobs = True
        if "uses:" in stripped:
            value = stripped.split("uses:", 1)[1].strip().strip("'\"")
            if not re.fullmatch(r"(?:actions|github/codeql-action)/[A-Za-z0-9_.-]+@[0-9a-f]{40}", value): findings.add("unsafe-workflow-action")
        if stripped.startswith("permissions:"):
            value = stripped.split(":", 1)[1].strip()
            if indent != 0:
                findings.add("unsafe-workflow-permissions")
            elif value.startswith(("{", "[")) or value in {"write-all", "read-all", "read", "write"} or "write" in value:
                findings.add("unsafe-workflow-permissions")
            else:
                top_permissions = "mapping"
        elif re.match(r"[A-Za-z-]+:\s*write\b", stripped):
            key = stripped.split(":", 1)[0]
            if not (codeql and key == "security-events"): findings.add("unsafe-workflow-permissions")
    if top_permissions is None: findings.add("unsafe-workflow-permissions")
    return [Finding(rule, path) for rule in sorted(findings)]

def audit_candidate(candidate_root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for base, dirs, files in os.walk(candidate_root, followlinks=False):
        relative_base = Path(base).relative_to(candidate_root)
        for name in dirs + files:
            relative = (relative_base / name).as_posix(); full = Path(base) / name
            findings += _path_findings(relative, candidate=True)
            if full.is_symlink(): findings.append(Finding("symlink", relative)); continue
            if full.is_file():
                if relative.startswith(".github/workflows/") and relative.endswith((".yml", ".yaml")): findings += audit_workflow(relative, full.read_bytes())
                else:
                    with full.open("rb") as handle:
                        findings += _scan_stream(handle, relative, full.stat().st_size)
    return sorted(set(findings))

def main() -> int:
    parser = argparse.ArgumentParser(); group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--staged", action="store_true"); group.add_argument("--candidate", type=Path)
    args = parser.parse_args(); findings = audit_staged_index(Path.cwd()) if args.staged else audit_candidate(args.candidate)
    for finding in findings: print(f"open-source guard: {finding.rule}: {finding.path}")
    return 1 if findings else 0

if __name__ == "__main__": raise SystemExit(main())
