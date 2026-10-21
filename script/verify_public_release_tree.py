#!/usr/bin/env python3
"""Read-only checks for a curated Track Downloader public-release candidate directory."""

from __future__ import annotations

import argparse
import errno
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path


INTERNAL_NAMES = {".agents", ".codex", ".git", ".hg", ".svn", ".superpowers", "artifacts"}
GENERATED_NAMES = {".build", ".swiftpm", "__pycache__", "_CodeSignature"}
MEDIA_EXTENSIONS = {
    ".aac",
    ".aiff",
    ".alac",
    ".flac",
    ".m4a",
    ".mp3",
    ".oga",
    ".ogg",
    ".opus",
    ".wav",
    ".webm",
}
PRIVATE_RUNTIME_NAMES = {
    ".track-downloader-archive.txt",
    "cookies.sqlite",
    "cookies.txt",
    "track-downloader-last-download.log",
    "track-downloader-quality-report.txt",
}
MAX_PUBLIC_FILE_BYTES = 10 * 1024 * 1024
SCAN_CHUNK_BYTES = 64 * 1024
SCAN_TAIL_BYTES = 128

SECRET_PATTERNS = (
    re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"),
    re.compile(r"\bgh[opusr]_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bsk_live_[A-Za-z0-9]{16,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
)
FIXED_SECRET_BYTE_PATTERNS = tuple(
    re.compile(pattern.pattern.encode("ascii")) for pattern in SECRET_PATTERNS[1:]
)
UNIX_USERNAME_BYTES = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
PRIVATE_KEY_HEADER = b"-----BEGIN "
PRIVATE_KEY_FOOTER = b"PRIVATE KEY-----"
UNIX_PATH_HEADERS = (b"/Users/", b"/home/")
WINDOWS_PATH_SUFFIX = b"\\Users\\"


def _failure_table(pattern: bytes) -> tuple[int, ...]:
    failure = [0] * len(pattern)
    matched = 0
    for index in range(1, len(pattern)):
        while matched and pattern[index] != pattern[matched]:
            matched = failure[matched - 1]
        if pattern[index] == pattern[matched]:
            matched += 1
        failure[index] = matched
    return tuple(failure)


PRIVATE_KEY_HEADER_FAILURE = _failure_table(PRIVATE_KEY_HEADER)
UNIX_PATH_HEADER_FAILURES = tuple(_failure_table(header) for header in UNIX_PATH_HEADERS)


def _advance_literal_match(
    pattern: bytes, failure: tuple[int, ...], matched: int, byte: int
) -> tuple[int, bool]:
    while matched and byte != pattern[matched]:
        matched = failure[matched - 1]
    if byte == pattern[matched]:
        matched += 1
    if matched == len(pattern):
        return failure[-1], True
    return matched, False


@dataclass(frozen=True, order=True)
class Finding:
    kind: str
    path: str
    detail: str


def _is_internal(relative: Path) -> bool:
    parts = relative.parts
    return any(part in INTERNAL_NAMES for part in parts) or (
        len(parts) >= 2 and parts[0] == "docs" and parts[1] == "superpowers"
    )


def _is_generated(relative: Path) -> bool:
    parts = relative.parts
    if any(part in GENERATED_NAMES for part in parts):
        return True
    return "Contents" in parts and "MacOS" in parts


def _is_private_runtime_file(path: Path) -> bool:
    name = path.name.lower()
    if name in PRIVATE_RUNTIME_NAMES or path.suffix.lower() in MEDIA_EXTENSIONS:
        return True
    if name.endswith(".info.json") or name.endswith(".log"):
        return True
    return (name == ".env" or name.startswith(".env.")) and name != ".env.example"


class _ContentScanner:
    """Bounded byte scanner for content signatures that may span read chunks."""

    def __init__(self) -> None:
        self.finding_kinds: set[str] = set()
        self._tail = b""
        self._private_key_header_index = 0
        self._private_key_active = False
        self._private_key_footer_index = 0
        self._private_key_at_start = False
        self._private_key_last_was_space = False
        self._unix_path_header_indexes = [0] * len(UNIX_PATH_HEADERS)
        self._unix_path_active = False
        self._unix_path_has_username = False
        self._windows_path_header_index = 0
        self._windows_path_active = False
        self._windows_path_has_username = False

    def _scan_private_key_byte(self, byte: int) -> None:
        if self._private_key_active:
            if self._private_key_footer_index:
                if byte == PRIVATE_KEY_FOOTER[self._private_key_footer_index]:
                    self._private_key_footer_index += 1
                    if self._private_key_footer_index == len(PRIVATE_KEY_FOOTER):
                        self.finding_kinds.add("possible-secret")
                        self._private_key_active = False
                    return
                self._private_key_footer_index = 0

            if byte == PRIVATE_KEY_FOOTER[0] and (
                self._private_key_at_start or self._private_key_last_was_space
            ):
                self._private_key_footer_index = 1
            elif byte not in b"ABCDEFGHIJKLMNOPQRSTUVWXYZ ":
                self._private_key_active = False
            self._private_key_at_start = False
            self._private_key_last_was_space = byte == ord(" ")

        self._private_key_header_index, found_header = _advance_literal_match(
            PRIVATE_KEY_HEADER,
            PRIVATE_KEY_HEADER_FAILURE,
            self._private_key_header_index,
            byte,
        )
        if found_header:
            self._private_key_active = True
            self._private_key_footer_index = 0
            self._private_key_at_start = True
            self._private_key_last_was_space = False

    def _scan_windows_header_byte(self, byte: int) -> bool:
        if self._windows_path_header_index == 0:
            self._windows_path_header_index = 1 if 65 <= byte <= 90 or 97 <= byte <= 122 else 0
            return False
        if self._windows_path_header_index == 1:
            if byte == ord(":"):
                self._windows_path_header_index = 2
            elif 65 <= byte <= 90 or 97 <= byte <= 122:
                self._windows_path_header_index = 1
            else:
                self._windows_path_header_index = 0
            return False

        suffix_index = self._windows_path_header_index - 2
        if byte == WINDOWS_PATH_SUFFIX[suffix_index]:
            self._windows_path_header_index += 1
            if self._windows_path_header_index == len(WINDOWS_PATH_SUFFIX) + 2:
                self._windows_path_header_index = 0
                return True
        else:
            self._windows_path_header_index = 1 if 65 <= byte <= 90 or 97 <= byte <= 122 else 0
        return False

    def _scan_personal_path_byte(self, byte: int) -> None:
        if self._unix_path_active:
            if byte in UNIX_USERNAME_BYTES:
                self._unix_path_has_username = True
            elif byte == ord("/") and self._unix_path_has_username:
                self.finding_kinds.add("personal-path")
                self._unix_path_active = False
            else:
                self._unix_path_active = False

        if self._windows_path_active:
            if byte == ord("\\") and self._windows_path_has_username:
                self.finding_kinds.add("personal-path")
                self._windows_path_active = False
            elif byte in (ord("\\"), ord("\r"), ord("\n")):
                self._windows_path_active = False
            else:
                self._windows_path_has_username = True

        for index, header in enumerate(UNIX_PATH_HEADERS):
            self._unix_path_header_indexes[index], found_header = _advance_literal_match(
                header,
                UNIX_PATH_HEADER_FAILURES[index],
                self._unix_path_header_indexes[index],
                byte,
            )
            if found_header:
                self._unix_path_active = True
                self._unix_path_has_username = False
        if self._scan_windows_header_byte(byte):
            self._windows_path_active = True
            self._windows_path_has_username = False

    def feed(self, chunk: bytes) -> None:
        combined = self._tail + chunk
        if any(pattern.search(combined) for pattern in FIXED_SECRET_BYTE_PATTERNS):
            self.finding_kinds.add("possible-secret")
        for byte in chunk:
            self._scan_private_key_byte(byte)
            self._scan_personal_path_byte(byte)
        self._tail = combined[-SCAN_TAIL_BYTES:]


def _scan_content(relative: Path, file_descriptor: int) -> list[Finding]:
    scanner = _ContentScanner()
    try:
        with os.fdopen(file_descriptor, "rb") as handle:
            while chunk := handle.read(SCAN_CHUNK_BYTES):
                scanner.feed(chunk)
    except OSError as exc:
        return [Finding("unreadable", relative.as_posix(), str(exc))]

    display_path = relative.as_posix()
    findings: list[Finding] = []
    if "possible-secret" in scanner.finding_kinds:
        findings.append(Finding("possible-secret", display_path, "high-confidence credential pattern"))
    if "personal-path" in scanner.finding_kinds:
        findings.append(Finding("personal-path", display_path, "personal absolute filesystem path"))
    return findings


def _finding_for_open_error(relative: Path, exc: OSError) -> Finding:
    if exc.errno == errno.ELOOP:
        return Finding("symlink", relative.as_posix(), "symlinks are not allowed")
    return Finding("unreadable", relative.as_posix(), str(exc))


def _same_snapshot(left: os.stat_result, right: os.stat_result) -> bool:
    return (
        left.st_dev,
        left.st_ino,
        left.st_mode,
        left.st_size,
        left.st_mtime_ns,
        left.st_ctime_ns,
    ) == (
        right.st_dev,
        right.st_ino,
        right.st_mode,
        right.st_size,
        right.st_mtime_ns,
        right.st_ctime_ns,
    )


def _record_changed_during_verification(findings: set[Finding], relative: Path) -> None:
    findings.add(
        Finding("changed-during-verification", relative.as_posix(), "entry changed after scanning")
    )


def _open_directory(name: str | Path, parent_descriptor: int | None = None) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if parent_descriptor is None:
        descriptor = os.open(name, flags)
    else:
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    try:
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            raise OSError(errno.ENOTDIR, "directory changed during verification", os.fspath(name))
    except OSError:
        os.close(descriptor)
        raise
    return descriptor


def _open_regular_file(name: str, parent_descriptor: int) -> tuple[int, os.stat_result]:
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_descriptor)
    try:
        file_status = os.fstat(descriptor)
        if not stat.S_ISREG(file_status.st_mode):
            raise OSError(errno.EINVAL, "file changed during verification", name)
    except OSError:
        os.close(descriptor)
        raise
    return descriptor, file_status


def _audit_directory(
    directory_descriptor: int, relative_directory: Path, findings: set[Finding]
) -> None:
    initial_status = os.fstat(directory_descriptor)
    try:
        names = os.listdir(directory_descriptor)
    except OSError as exc:
        findings.add(Finding("unreadable", relative_directory.as_posix(), str(exc)))
        return

    for name in names:
        relative = relative_directory / name
        display_path = relative.as_posix()
        try:
            path_status = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
        except OSError as exc:
            findings.add(_finding_for_open_error(relative, exc))
            continue

        if stat.S_ISLNK(path_status.st_mode):
            findings.add(Finding("symlink", display_path, "symlinks are not allowed"))
            continue
        if _is_internal(relative):
            findings.add(Finding("internal-path", display_path, "private planning or VCS metadata"))
            continue
        if _is_generated(relative):
            findings.add(Finding("generated-artifact", display_path, "build or signed output"))
            continue

        if stat.S_ISDIR(path_status.st_mode):
            try:
                child_descriptor = _open_directory(name, directory_descriptor)
            except OSError as exc:
                findings.add(_finding_for_open_error(relative, exc))
                continue
            try:
                if not _same_snapshot(os.fstat(child_descriptor), path_status):
                    _record_changed_during_verification(findings, relative)
                else:
                    _audit_directory(child_descriptor, relative, findings)
            finally:
                os.close(child_descriptor)
            try:
                final_status = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            except OSError as exc:
                findings.add(_finding_for_open_error(relative, exc))
                continue
            if not _same_snapshot(final_status, path_status):
                _record_changed_during_verification(findings, relative)
            continue

        if not stat.S_ISREG(path_status.st_mode):
            findings.add(Finding("unreadable", display_path, "non-regular files are not allowed"))
            continue
        if _is_private_runtime_file(relative):
            findings.add(
                Finding("private-runtime-data", display_path, "media, log, cookie, archive, or environment data")
            )
            continue

        try:
            file_descriptor, file_status = _open_regular_file(name, directory_descriptor)
        except OSError as exc:
            findings.add(_finding_for_open_error(relative, exc))
            continue
        if not _same_snapshot(file_status, path_status):
            os.close(file_descriptor)
            _record_changed_during_verification(findings, relative)
            continue
        if file_status.st_size > MAX_PUBLIC_FILE_BYTES:
            os.close(file_descriptor)
            findings.add(
                Finding("large-file", display_path, f"file exceeds {MAX_PUBLIC_FILE_BYTES} bytes")
            )
            continue
        findings.update(_scan_content(relative, file_descriptor))
        try:
            final_status = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
        except OSError as exc:
            findings.add(_finding_for_open_error(relative, exc))
            continue
        if not _same_snapshot(final_status, file_status):
            _record_changed_during_verification(findings, relative)

    if not _same_snapshot(os.fstat(directory_descriptor), initial_status):
        _record_changed_during_verification(findings, relative_directory)


def audit_public_tree(root: Path) -> list[Finding]:
    findings: set[Finding] = set()
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        raise ValueError("candidate verification requires no-follow directory descriptors on supported macOS")
    try:
        root_descriptor = _open_directory(root)
    except OSError as exc:
        raise ValueError(f"candidate is not a directory: {root}") from exc
    try:
        initial_root_status = os.fstat(root_descriptor)
        _audit_directory(root_descriptor, Path(), findings)
        final_status = os.stat(root, follow_symlinks=False)
        if not _same_snapshot(final_status, initial_root_status):
            _record_changed_during_verification(findings, Path())
    finally:
        os.close(root_descriptor)

    return sorted(findings)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path, help="Explicit curated directory to inspect without modifying it.")
    args = parser.parse_args(argv)

    try:
        findings = audit_public_tree(args.candidate)
    except ValueError as exc:
        parser.error(str(exc))

    if findings:
        print(f"Public release check failed with {len(findings)} finding(s):")
        for finding in findings:
            print(f"- [{finding.kind}] {finding.path}: {finding.detail}")
        return 1

    print(f"Public release check passed: {args.candidate.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
