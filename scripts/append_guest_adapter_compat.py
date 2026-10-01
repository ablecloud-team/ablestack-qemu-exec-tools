#!/usr/bin/env python3
"""Append complete guest adapter hashes from a reviewed Tools ISO."""
# Copyright 2026 ABLECLOUD. Apache-2.0.
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from guest_adapter_compat import CATALOG, FILES, IDENTIFIER


PROFILES = {
    "windows": ("windows-read", "windows-action", "windows-profile"),
    "rocky": ("rocky-read", "linux-action", "linux-profile"),
    "ubuntu": ("ubuntu-read", "linux-action", "linux-profile"),
}


def iso_file(iso, name):
    for path in ("/process-management/" + name, "/" + name):
        command = subprocess.run(
            ["isoinfo", "-i", str(iso), "-R", "-x", path],
            capture_output=True, check=False,
        )
        if command.returncode == 0 and command.stdout:
            return command.stdout
    raise ValueError("Missing adapter file in ISO: " + name)


def hashes(source, profile, directory=False):
    result = {}
    for name in FILES[profile]:
        data = (source / name).read_bytes() if directory else iso_file(source, name)
        # New approvals bind exact ISO bytes. The host retains normalized
        # line-ending checks only for previously approved guest bundles.
        result[name] = hashlib.sha256(data).hexdigest()
    return result


def append(catalog, source, family, identifier, directory=False):
    if family not in PROFILES or not IDENTIFIER.fullmatch(identifier):
        raise ValueError("Invalid family or artifact ID")
    if source.is_symlink() or not (source.is_dir() if directory else source.is_file()):
        raise ValueError("Source must be a regular reviewed artifact")
    value = json.loads(catalog.read_text(encoding="utf-8")) if catalog.exists() else {
        "schemaVersion": 1, "protocolVersion": "1.0", "bundles": [],
    }
    if value.get("schemaVersion") != 1 or value.get("protocolVersion") != "1.0" or not isinstance(value.get("bundles"), list):
        raise ValueError("Unsupported catalog")
    added = []
    for profile in PROFILES[family]:
        digest = hashes(source, profile, directory)
        if any(item["profile"] == profile and item["sha256"] == digest for item in value["bundles"]):
            continue
        name = identifier + "-" + profile
        if any(item["id"] == name for item in value["bundles"]):
            raise ValueError("Artifact ID already exists")
        value["bundles"].append({"id": name, "profile": profile, "sha256": digest})
        added.append(name)
    catalog.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    return added


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--iso", type=Path)
    source.add_argument("--directory", type=Path)
    parser.add_argument("--family", required=True, choices=PROFILES)
    parser.add_argument("--id", required=True)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    args = parser.parse_args()
    print("\n".join(append(args.catalog, args.directory or args.iso, args.family, args.id, args.directory is not None)))
