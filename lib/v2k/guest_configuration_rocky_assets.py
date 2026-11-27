#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Verify the qualified Rocky offline payload without changing the host RPM DB."""
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

KEY_SHA = "3a66e521e7a4abac9768d889c7cd60a8250f59512b275cf576c8a10ff34624c1"


def payloads(directory):
    path = Path(directory)
    m = json.loads((path / "assets.json").read_text())
    if (
        m.get("os"),
        m.get("os_version"),
        m.get("arch"),
        m.get("provenance"),
        m.get("key_sha256"),
    ) != ("rocky", "9.7", "x86_64", "vendor-signed-rpm", KEY_SHA):
        raise ValueError("GUEST_CONFIG_PAYLOAD_UNQUALIFIED")
    key = path / "RPM-GPG-KEY-Rocky-9"
    if hashlib.sha256(key.read_bytes()).hexdigest() != KEY_SHA:
        raise ValueError("GUEST_CONFIG_PAYLOAD_HASH_MISMATCH")
    files = []
    names = set()
    with tempfile.TemporaryDirectory(prefix="v2k-rocky-rpmdb-") as db:
        subprocess.run(
            ["rpmkeys", "--dbpath", db, "--import", str(key.resolve())],
            check=True,
            capture_output=True,
        )
        for item in m["files"]:
            file = path / item["file"]
            if (
                file.parent != path
                or not re.fullmatch(r"[A-Za-z0-9+_.~-]+\.rpm", file.name)
                or hashlib.sha256(file.read_bytes()).hexdigest() != item["sha256"]
            ):
                raise ValueError("GUEST_CONFIG_PAYLOAD_HASH_MISMATCH")
            result = subprocess.run(
                ["rpmkeys", "--dbpath", db, "--checksig", str(file.resolve())],
                check=True,
                capture_output=True,
                text=True,
            )
            if "signatures OK" not in result.stdout:
                raise ValueError("GUEST_CONFIG_PAYLOAD_SIGNATURE_INVALID")
            names.add(item["name"])
            files.append(file)
    if names != {"qemu-guest-agent", "liburing", "numactl-libs"} or len(files) != 3:
        raise ValueError("GUEST_CONFIG_PAYLOAD_UNQUALIFIED")
    return files, m
