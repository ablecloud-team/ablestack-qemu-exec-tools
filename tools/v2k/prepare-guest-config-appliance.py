#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Stage a pinned upstream NTFS-capable appliance without changing host packages."""
import argparse
import sys
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

VERSION = "1.58.1"
SHA256 = "6779ce3fc820a28c1607729892e53a1ba418be4480f52e0457bb381eab408a72"
URL = (
    "https://download.libguestfs.org/binaries/appliance/appliance-"
    + VERSION
    + ".tar.xz"
)
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib/v2k"))
from guest_configuration_assets import file_sha, metadata


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--archive-only",
        action="store_true",
        help="Package the original compressed appliance for extraction into a private cache",
    )
    parser.add_argument(
        "--archive", help="Already downloaded archive, still SHA-verified"
    )
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        archive = (
            Path(args.archive) if args.archive else Path(temp) / "appliance.tar.xz"
        )
        if not args.archive:
            with (
                urllib.request.urlopen(URL, timeout=180) as response,
                archive.open("wb") as file,
            ):
                shutil.copyfileobj(response, file)
        if file_sha(archive) != SHA256:
            raise ValueError("APPLIANCE_ARCHIVE_HASH_MISMATCH")
        if args.archive_only:
            target = output / "appliance-1.58.1.tar.xz"
            if target.exists():
                if file_sha(target) != SHA256:
                    raise ValueError("APPLIANCE_OUTPUT_ALREADY_EXISTS")
            else:
                shutil.copyfile(archive, target)
            info = metadata()
            info["archive_file"] = target.name
            (output / "assets.json").write_text(json.dumps(info, indent=2) + "\n")
            print(json.dumps(info))
            return
        allowed = {"kernel", "initrd", "root", "README.fixed"}
        with tarfile.open(archive, "r:xz") as tar:
            for member in tar:
                if member.isdir() and member.name.rstrip("/") == "appliance":
                    continue
                if not member.isfile() or member.name not in {
                    "appliance/" + n for n in allowed
                }:
                    raise ValueError("APPLIANCE_ARCHIVE_PATH_INVALID")
                with (
                    tar.extractfile(member) as source,
                    (output / Path(member.name).name).open("wb") as target,
                ):
                    shutil.copyfileobj(source, target)
    files = {name: file_sha(output / name) for name in allowed}
    info = {
        "version": VERSION,
        "url": URL,
        "archive_sha256": SHA256,
        "files": files,
        "license_notice": "libguestfs GPLv2+/LGPLv2+; appliance contains separately licensed distribution packages; see upstream sources",
    }
    (output / "assets.json").write_text(json.dumps(info, indent=2) + "\n")
    print(json.dumps(info))


if __name__ == "__main__":
    main()
