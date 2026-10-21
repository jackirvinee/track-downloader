#!/usr/bin/env python3
"""Validate the platform parity catalog and its macOS-source diff contract."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path


CATALOG_PATH = Path("platform-parity.json")
MAC_SOURCE_PREFIXES = ("Sources/TrackDownloader/", "Sources/TrackDownloaderCore/")
IMPLEMENTATION_STATES = {"implemented", "partial", "planned"}
VERIFICATION_STATES = {"source-tested", "external-required", "device-verified", "not-tested"}
EXPECTED_PRINCIPLES = {
    "nativeUIs": "separate",
    "translation": "manual-only",
    "parityMechanism": "capability-contract",
}
CAPABILITY_ID = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")


def _safe_relative_path(value: object) -> bool:
    if not isinstance(value, str) or not value or value.startswith("/") or "\\" in value:
        return False
    return all(part not in {"", ".", ".."} for part in value.split("/"))


def validate_catalog(repo_root: Path, catalog_path: Path = CATALOG_PATH) -> list[str]:
    try:
        catalog = json.loads((repo_root / catalog_path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        return [f"cannot read {catalog_path.as_posix()}: {error}"]

    if not isinstance(catalog, dict):
        return ["catalog root must be an object"]

    errors: list[str] = []
    if catalog.get("schemaVersion") != 1:
        errors.append("schemaVersion must equal 1")

    principles = catalog.get("principles")
    if not isinstance(principles, dict):
        errors.append("principles must be an object")
    else:
        for key, expected in EXPECTED_PRINCIPLES.items():
            if principles.get(key) != expected:
                errors.append(f"principles.{key} must equal {expected}")

    capabilities = catalog.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities:
        errors.append("capabilities must be a non-empty array")
        return errors

    seen_ids: set[str] = set()
    for index, capability in enumerate(capabilities):
        if not isinstance(capability, dict):
            errors.append(f"capabilities[{index}] must be an object")
            continue
        capability_id = capability.get("id")
        if not isinstance(capability_id, str) or CAPABILITY_ID.fullmatch(capability_id) is None:
            errors.append(f"capabilities[{index}].id must be kebab-case")
            capability_label = f"capabilities[{index}]"
        else:
            capability_label = capability_id
            if capability_id in seen_ids:
                errors.append(f"duplicate capability id: {capability_id}")
            seen_ids.add(capability_id)

        if not isinstance(capability.get("description"), str) or not capability["description"].strip():
            errors.append(f"{capability_label}.description must be non-empty")

        for platform in ("macos", "windows"):
            platform_label = f"{capability_label}.{platform}"
            record = capability.get(platform)
            if not isinstance(record, dict):
                errors.append(f"{platform_label} must be an object")
                continue

            status = record.get("status")
            verification = record.get("verification")
            evidence = record.get("evidence")
            if status not in IMPLEMENTATION_STATES:
                errors.append(f"{platform_label}.status is invalid: {status}")
            if verification not in VERIFICATION_STATES:
                errors.append(f"{platform_label}.verification is invalid: {verification}")
            if not isinstance(evidence, list):
                errors.append(f"{platform_label}.evidence must be an array")
                continue
            if status in {"implemented", "partial"} and not evidence:
                errors.append(f"{platform_label} requires evidence")
            if status == "planned" and evidence:
                errors.append(f"{platform_label}.evidence must be empty while planned")
            if status == "implemented" and verification not in {"source-tested", "device-verified"}:
                errors.append(f"{platform_label}.verification does not prove implemented status")
            if status == "planned" and verification not in {"not-tested", "external-required"}:
                errors.append(f"{platform_label}.verification is incompatible with planned status")
            for evidence_path in evidence:
                if not _safe_relative_path(evidence_path):
                    errors.append(f"{platform_label}.evidence contains an unsafe path: {evidence_path}")
                elif not (repo_root / evidence_path).is_file():
                    errors.append(f"{platform_label}.evidence path does not exist: {evidence_path}")

    return errors


def _git(repo_root: Path, arguments: list[str]) -> str:
    try:
        return subprocess.run(
            ["git", *arguments],
            cwd=repo_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() or "git command failed"
        raise ValueError(detail) from error


def changed_paths(repo_root: Path, base_ref: str, head_ref: str) -> set[str]:
    if base_ref == "0" * 40:
        output = _git(repo_root, ["diff-tree", "--root", "--no-commit-id", "--name-only", "-r", head_ref])
    else:
        output = _git(repo_root, ["diff", "--name-only", base_ref, head_ref, "--"])
    return {line for line in output.splitlines() if line}


def validate_parity_diff(paths: set[str]) -> list[str]:
    mac_source_changes = sorted(
        path for path in paths if any(path.startswith(prefix) for prefix in MAC_SOURCE_PREFIXES)
    )
    if mac_source_changes and CATALOG_PATH.as_posix() not in paths:
        return [
            "macOS source changed without platform-parity.json changing: "
            + ", ".join(mac_source_changes)
        ]
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", type=Path, default=CATALOG_PATH)
    parser.add_argument("--base")
    parser.add_argument("--head")
    args = parser.parse_args()

    errors = validate_catalog(Path.cwd(), args.catalog)
    if bool(args.base) != bool(args.head):
        errors.append("--base and --head must be provided together")
    elif args.base and args.head:
        try:
            errors.extend(validate_parity_diff(changed_paths(Path.cwd(), args.base, args.head)))
        except ValueError as error:
            errors.append(f"cannot inspect git diff: {error}")

    for error in errors:
        print(f"platform parity: {error}")
    if errors:
        return 1
    print("platform parity: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
