#!/usr/bin/env python3
"""Hash the four guest-only Tools ISO artifacts for Cloud catalog registration."""
# Copyright 2026 ABLECLOUD. Apache-2.0.
import argparse
import hashlib
import json
import re
from pathlib import Path

TARGETS = {
    "rocky": ["8.x", "9.x", "10.x"],
    "ubuntu": ["22.04", "24.04", "26.04"],
    "debian": ["12", "13"],
    "windows": ["11", "Server 2019", "Server 2022", "Server 2025"],
}


def sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def write_manifest(root, source_commit, workflow_run_id, version):
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("Invalid source commit")
    if not re.fullmatch(r"[0-9]+", workflow_run_id):
        raise ValueError("Invalid workflow run ID")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", version):
        raise ValueError("Invalid version")
    root = Path(root).resolve(strict=True)
    artifacts = []
    expected = set()
    for family, versions in TARGETS.items():
        name = "ABLESTACK-Tools-%s-%s.iso" % (family, version)
        path = root / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError("Missing or unsafe ISO: " + name)
        expected.add(path)
        artifacts.append({"family": family, "versions": versions, "arch": "x86_64",
                          "path": name, "sha256": sha256(path), "bytes": path.stat().st_size})
    extras = set(root.glob("*.iso")) - expected
    if extras:
        raise ValueError("Unexpected ISO: " + str(sorted(extras)[0]))
    manifest = {"schemaVersion": 1, "sourceCommit": source_commit,
                "workflowRunId": workflow_run_id, "version": version,
                "artifacts": artifacts}
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (root / "SHA256SUMS").write_text(
        "".join(item["sha256"] + "  " + item["path"] + "\n" for item in artifacts),
        encoding="ascii")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--workflow-run-id", required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    print(json.dumps(write_manifest(args.root, args.source_commit,
                                    args.workflow_run_id, args.version)))
