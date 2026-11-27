#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Extend only the fresh vendor QGA allow list for the Mold file exchange."""
import re
from pathlib import Path

FILES = (
    "guest-file-open",
    "guest-file-close",
    "guest-file-read",
    "guest-file-write",
    "guest-file-seek",
    "guest-file-flush",
)


def configure(text):
    pattern = r'^FILTER_RPC_ARGS="--allow-rpcs=([^"\n]+)"$'
    matches = list(re.finditer(pattern, text, re.M))
    if len(matches) != 1:
        raise ValueError("EXISTING_QGA_POLICY_REQUIRES_REVIEW")
    match = matches[0]
    allowed = match.group(1).split(",")
    if "guest-exec" in allowed or "guest-exec-status" in allowed:
        raise ValueError("QGA_VENDOR_POLICY_UNQUALIFIED")
    allowed += [method for method in FILES if method not in allowed]
    return (
        text[: match.start()]
        + 'FILTER_RPC_ARGS="--allow-rpcs='
        + ",".join(allowed)
        + '"'
        + text[match.end() :]
    )


if __name__ == "__main__":
    path = Path("/etc/sysconfig/qemu-ga")
    before = path.read_text()
    backup = Path("/var/lib/ablestack-v2k/guest-config/backup/qemu-ga.sysconfig.vendor")
    if backup.exists() and backup.read_text() != before:
        raise ValueError("QGA_POLICY_OWNERSHIP_CONFLICT")
    backup.write_text(before)
    backup.chmod(0o600)
    path.write_text(configure(before))
