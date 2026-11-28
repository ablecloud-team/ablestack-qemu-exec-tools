#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Stage fixed OS offline payloads from Ubuntu indexes with SHA verification.

Release CI must supply an Ubuntu archive keyring and verify InRelease before use.
Local qualification may use --tls-index and records that narrower provenance.
"""
import argparse, gzip, hashlib, json, subprocess, tempfile, urllib.request
from pathlib import Path


def fetch(url):
    with urllib.request.urlopen(url, timeout=90) as reply:
        return reply.read()


def records(data):
    for paragraph in data.decode().split("\n\n"):
        value = {}
        for line in paragraph.splitlines():
            if ": " in line and not line.startswith(" "):
                k, v = line.split(": ", 1)
                value[k] = v
        if value:
            yield value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--ubuntu-keyring")
    parser.add_argument("--tls-index", action="store_true")
    parser.add_argument("--ubuntu-version", choices=["22.04", "24.04"], default="22.04")
    args = parser.parse_args()
    if not args.ubuntu_keyring and not args.tls_index:
        parser.error(
            "Supply the archive keyring (release) or explicit --tls-index (local qualification)"
        )
    base = "https://archive.ubuntu.com/ubuntu/"
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    wanted = {"qemu-guest-agent", "liburing2"}
    selected = {}
    provenance = []
    for suite in (["noble-updates", "noble"] if args.ubuntu_version == "24.04" else ["jammy-updates", "jammy"]):
        release = fetch(base + "dists/" + suite + "/InRelease")
        if args.ubuntu_keyring:
            with tempfile.NamedTemporaryFile() as f:
                f.write(release)
                f.flush()
                subprocess.run(
                    ["gpgv", "--keyring", args.ubuntu_keyring, f.name],
                    check=True,
                    capture_output=True,
                )
        text = release.decode()
        for component in ["main", "universe"]:
            path = component + "/binary-amd64/Packages.gz"
            expected = None
            for line in text.splitlines():
                fields = line.split()
                if len(fields) == 3 and fields[2] == path and len(fields[0]) == 64:
                    expected = fields[0]
            if not expected:
                raise RuntimeError("Index SHA256 missing")
            compressed = fetch(base + "dists/" + suite + "/" + component + "/binary-amd64/by-hash/SHA256/" + expected)
            if hashlib.sha256(compressed).hexdigest() != expected:
                raise RuntimeError("Index digest mismatch")
            provenance.append(
                {
                    "suite": suite,
                    "component": component,
                    "index_sha256": expected,
                    "inrelease_sha256": hashlib.sha256(release).hexdigest(),
                }
            )
            for value in records(gzip.decompress(compressed)):
                name = value.get("Package")
                arch = value.get("Architecture")
                if name in wanted and name not in selected and arch == "amd64":
                    selected[name] = value
        if set(selected) == wanted:
            break
    if set(selected) != wanted:
        raise RuntimeError("Required offline packages missing")
    files = []
    for name, value in selected.items():
        data = fetch(base + value["Filename"])
        sha = hashlib.sha256(data).hexdigest()
        if sha != value["SHA256"]:
            raise RuntimeError("Payload digest mismatch")
        file = output / Path(value["Filename"]).name
        file.write_bytes(data)
        files.append(
            {
                "name": name,
                "version": value["Version"],
                "file": file.name,
                "sha256": sha,
                "url": base + value["Filename"],
            }
        )
    (output / "assets.json").write_text(
        json.dumps(
            {
                "version": 1,
                "os": "ubuntu",
                "os_version": args.ubuntu_version,
                "arch": "amd64",
                "provenance": (
                    "signed-inrelease"
                    if args.ubuntu_keyring
                    else "official-https-index-sha256"
                ),
                "indexes": provenance,
                "files": files,
            },
            indent=2,
        )
        + "\n"
    )
    print(json.dumps({"output": str(output), "files": files}))


if __name__ == "__main__":
    main()
