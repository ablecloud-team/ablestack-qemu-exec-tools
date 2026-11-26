#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Stage the pinned Windows QGA MSI without duplicating a full VirtIO ISO."""
import argparse, hashlib, json, urllib.request
from pathlib import Path

URL = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-qemu-ga/qemu-ga-win-110.2.3-2.el10/qemu-ga-x86_64.msi"
SHA256 = "19dcf8abc30f70c2eb6e87282601fd0476e4e0b19936f63d9c80be30db0796ed"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    root = Path(args.output)
    path = root / "guest-agent/qemu-ga-x86_64.msi"
    path.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(URL, timeout=120) as response:
        data = response.read(32 * 1024 * 1024 + 1)
    if len(data) > 32 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError("WINDOWS_QGA_PAYLOAD_HASH_MISMATCH")
    path.write_bytes(data)
    metadata = {
        "version": "110.2.3",
        "source_url": URL,
        "license": "GPL-2.0-or-later",
        "upstream_source": "https://download.qemu.org/qemu-10.2.3.tar.xz",
        "files": {"guest-agent/qemu-ga-x86_64.msi": SHA256},
    }
    (root / "assets.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata))


if __name__ == "__main__":
    main()
