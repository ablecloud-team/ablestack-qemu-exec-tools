#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Rocky 9.7 x86_64 QGA payload; vendor RPM signatures plus pinned key."""
import argparse
import gzip
import hashlib
import json
import subprocess
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

KEY_URL = "https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-9"
KEY_SHA = "3a66e521e7a4abac9768d889c7cd60a8250f59512b275cf576c8a10ff34624c1"
BASE = "https://dl.rockylinux.org/vault/rocky/9.7/"


def fetch(url):
    with urllib.request.urlopen(url, timeout=90) as reply:
        return reply.read()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    key = fetch(KEY_URL)
    if hashlib.sha256(key).hexdigest() != KEY_SHA:
        raise ValueError("ROCKY_VENDOR_KEY_HASH_MISMATCH")
    key_path = output / "RPM-GPG-KEY-Rocky-9"
    key_path.write_bytes(key)
    wanted = {"qemu-guest-agent", "liburing", "numactl-libs"}
    selected = {}
    indexes = []
    ns = {
        "r": "http://linux.duke.edu/metadata/repo",
        "p": "http://linux.duke.edu/metadata/common",
    }
    for repo in ("BaseOS", "AppStream"):
        base = BASE + repo + "/x86_64/os/"
        repomd = fetch(base + "repodata/repomd.xml")
        record = ET.fromstring(repomd).find("r:data[@type='primary']", ns)
        relative = record.find("r:location", ns).get("href")
        sha = record.find("r:checksum", ns)
        if (
            sha.get("type") != "sha256"
            or not relative.startswith("repodata/")
            or ".." in relative
        ):
            raise ValueError("ROCKY_REPOSITORY_METADATA_INVALID")
        compressed = fetch(base + relative)
        if hashlib.sha256(compressed).hexdigest() != sha.text:
            raise ValueError("ROCKY_REPOSITORY_HASH_MISMATCH")
        indexes.append(
            {
                "url": base + relative,
                "sha256": sha.text,
                "repomd_sha256": hashlib.sha256(repomd).hexdigest(),
            }
        )
        for package in ET.fromstring(gzip.decompress(compressed)).findall(
            "p:package", ns
        ):
            name = package.findtext("p:name", namespaces=ns)
            if (
                name not in wanted
                or package.findtext("p:arch", namespaces=ns) != "x86_64"
            ):
                continue
            location = package.find("p:location", ns).get("href")
            checksum = package.find("p:checksum", ns)
            if (
                not location.startswith("Packages/")
                or ".." in location
                or checksum.get("type") != "sha256"
            ):
                raise ValueError("ROCKY_PACKAGE_METADATA_INVALID")
            version = package.find("p:version", ns)
            selected[name] = {
                "name": name,
                "version": version.get("ver") + "-" + version.get("rel"),
                "file": Path(location).name,
                "url": base + location,
                "sha256": checksum.text,
            }
    if set(selected) != wanted:
        raise ValueError("ROCKY_OFFLINE_PACKAGES_MISSING")
    with tempfile.TemporaryDirectory(prefix="v2k-rocky-rpmdb-") as db:
        subprocess.run(
            ["rpmkeys", "--dbpath", db, "--import", str(key_path.resolve())], check=True
        )
        for item in selected.values():
            data = fetch(item["url"])
            if hashlib.sha256(data).hexdigest() != item["sha256"]:
                raise ValueError("ROCKY_PACKAGE_HASH_MISMATCH")
            path = output / item["file"]
            path.write_bytes(data)
            result = subprocess.run(
                ["rpmkeys", "--dbpath", db, "--checksig", str(path.resolve())],
                text=True,
                capture_output=True,
                check=True,
            )
            if "signatures OK" not in result.stdout:
                raise ValueError("ROCKY_PACKAGE_SIGNATURE_INVALID")
    metadata = {
        "version": 1,
        "os": "rocky",
        "os_version": "9.7",
        "arch": "x86_64",
        "provenance": "vendor-signed-rpm",
        "key_sha256": KEY_SHA,
        "indexes": indexes,
        "files": list(selected.values()),
    }
    (output / "assets.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata))


if __name__ == "__main__":
    main()
