#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Pinned, immutable appliance cache; keep large sparse files outside RPM payloads."""
import fcntl, hashlib, json, os, subprocess, tarfile, tempfile
from pathlib import Path

VERSION = "1.58.1"
ARCHIVE_SHA = "6779ce3fc820a28c1607729892e53a1ba418be4480f52e0457bb381eab408a72"
URL = "https://download.libguestfs.org/binaries/appliance/appliance-1.58.1.tar.xz"
FILES = {
    "root": "e4991405b724d7e943baa46c3d478d5c96900a63f20316303e9fc5b8ba74a463",
    "initrd": "275b72afdce807b285ef571450d2b2d99b940b09fe3faeeeab60dba27fdcda15",
    "README.fixed": "c19f8d7ecfc4229506f3bb921ccad8f18d6b2b595bfd3d4095c543e9bb5a2e91",
    "kernel": "c734236eb8402c0c60ff760a3b093fde7a2a5f1eb66e6955c548a6c2e23ecba9",
}


def file_sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def metadata():
    return {
        "version": VERSION,
        "url": URL,
        "archive_sha256": ARCHIVE_SHA,
        "files": FILES,
        "license_notice": "libguestfs GPLv2+/LGPLv2+; separately licensed distribution packages; upstream sources at libguestfs.org",
    }


def resolve_appliance(directory):
    directory = Path(directory)
    info = json.loads((directory / "assets.json").read_text())
    if not info.get("archive_file"):
        return directory
    if (
        info["version"] != VERSION
        or info["archive_sha256"] != ARCHIVE_SHA
        or info["archive_file"] != "appliance-1.58.1.tar.xz"
    ):
        raise ValueError("GUEST_CONFIG_APPLIANCE_UNQUALIFIED")
    archive = directory / info["archive_file"]
    if file_sha(archive) != ARCHIVE_SHA:
        raise ValueError("GUEST_CONFIG_APPLIANCE_HASH_MISMATCH")
    base = Path(
        os.environ.get(
            "V2K_GUEST_CONFIG_CACHE", "/var/cache/ablestack/v2k/guest-config"
        )
    )
    base.mkdir(mode=0o700, parents=True, exist_ok=True)
    cache = base / ("appliance-" + VERSION + "-" + ARCHIVE_SHA[:12])
    with (base / ".appliance.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not cache.exists():
            # Verify all archive paths before invoking GNU tar, which retains holes.
            with tarfile.open(archive, "r:xz") as tar:
                for entry in tar:
                    if entry.isdir() and entry.name.rstrip("/") == "appliance":
                        continue
                    if not entry.isfile() or entry.name not in {
                        "appliance/" + n for n in FILES
                    }:
                        raise ValueError("APPLIANCE_ARCHIVE_PATH_INVALID")
            with tempfile.TemporaryDirectory(
                prefix=".appliance-stage-", dir=base
            ) as temp:
                subprocess.run(
                    [
                        "tar",
                        "-xJf",
                        str(archive),
                        "--sparse",
                        "--no-same-owner",
                        "--no-same-permissions",
                        "-C",
                        temp,
                    ],
                    check=True,
                    timeout=180,
                )
                staged = Path(temp) / "appliance"
                if any(file_sha(staged / name) != sha for name, sha in FILES.items()):
                    raise ValueError("GUEST_CONFIG_APPLIANCE_HASH_MISMATCH")
                (staged / "assets.json").write_text(json.dumps(metadata()))
                for name in FILES:
                    (staged / name).chmod(0o444)
                staged.rename(cache)
    return cache
