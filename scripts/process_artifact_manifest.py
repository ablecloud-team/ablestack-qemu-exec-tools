#!/usr/bin/env python3
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership. The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License. You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied. See the License for the
# specific language governing permissions and limitations
# under the License.
"""Record release ISO identities for Cloud's administrator-managed Tools catalog."""

import argparse
import hashlib
import json
import re
from pathlib import Path

TARGETS = (
    ("rocky", "9.6", "rocky/ABLESTACK-Tools-rocky9.6-{version}.iso"),
    ("rocky", "9.7", "rocky/ABLESTACK-Tools-rocky9.7-{version}.iso"),
    ("rocky", "9.8", "rocky/ABLESTACK-Tools-rocky9.8-{version}.iso"),
    ("rocky", "10.2", "rocky/ABLESTACK-Tools-rocky10.2-{version}.iso"),
    ("ubuntu", "22.04,24.04,26.04", "ubuntu/ABLESTACK-Tools-ubuntu-{version}.iso"),
    ("windows", "2022,2025", "windows/ABLESTACK-Tools-windows-{version}.iso"),
)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def write_manifest(root, source_commit, workflow_run_id, version, packages_root=None):
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("source commit must be a full lowercase SHA")
    if not re.fullmatch(r"[0-9]+", workflow_run_id):
        raise ValueError("workflow run ID must be numeric")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", version):
        raise ValueError("unsafe artifact version")
    root = Path(root).resolve(strict=True)
    artifacts = []
    for os_id, os_versions, pattern in TARGETS:
        relative = pattern.format(version=version)
        path = root / relative
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError("missing or unsafe ISO: " + relative)
        artifacts.append({
            "os": os_id,
            "versions": os_versions.split(","),
            "arch": "x86_64",
            "path": relative,
            "sha256": digest(path),
            "bytes": path.stat().st_size,
        })
    extras = set(root.rglob("*.iso")) - {root / item["path"] for item in artifacts}
    if extras:
        raise ValueError("unexpected ISO: " + str(sorted(extras)[0]))
    packages = []
    if packages_root is not None:
        packages_root = Path(packages_root).resolve(strict=True)
        for package_type in ("rpm", "deb", "msi"):
            paths = sorted((packages_root / package_type).rglob("*." + package_type))
            if not paths:
                raise ValueError("missing " + package_type + " package")
            for path in paths:
                if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
                    raise ValueError("unsafe package: " + str(path))
                packages.append({
                    "type": package_type,
                    "path": path.relative_to(packages_root).as_posix(),
                    "sha256": digest(path),
                    "bytes": path.stat().st_size,
                })
    manifest = {
        "schemaVersion": 1,
        "sourceCommit": source_commit,
        "workflowRunId": workflow_run_id,
        "version": version,
        "artifacts": artifacts,
        "packages": packages,
    }
    (root / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (root / "SHA256SUMS").write_text(
        "".join(item["sha256"] + "  " + item["path"] + "\n" for item in artifacts),
        encoding="ascii",
    )
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--workflow-run-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--packages-root")
    args = parser.parse_args()
    print(json.dumps(write_manifest(
        args.root, args.source_commit, args.workflow_run_id, args.version, args.packages_root
    ), ensure_ascii=False))
