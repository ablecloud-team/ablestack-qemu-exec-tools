#!/usr/bin/env python3
"""Smoke test for large CBT payload delivery to patch_apply.py."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PATCH_APPLY = ROOT / "lib" / "v2k" / "patch_apply.py"
TRANSFER_PATCH = ROOT / "lib" / "v2k" / "transfer_patch.sh"


def main() -> None:
    source_size = 1024 * 1024
    areas = [
        {"offset": offset, "length": 16}
        for offset in range(0, 640_000, 64)
    ]
    payload = json.dumps(
        {
            "areas": areas,
            "coverage": {
                "complete": True,
                "start_offset": 0,
                "end_offset": source_size,
                "disk_capacity": source_size,
                "pages": 5,
                "mode": "delta",
            },
        },
        separators=(",", ":"),
    )
    if len(payload.encode("utf-8")) <= 131_072:
        raise AssertionError("test payload must exceed Linux's common single-argument limit")

    with tempfile.TemporaryDirectory(prefix="v2k-areas-file-") as tmp_dir:
        tmp = Path(tmp_dir)
        source = tmp / "source.raw"
        target = tmp / "target.raw"
        areas_file = tmp / "areas.json"

        source_bytes = bytes((index % 251 for index in range(source_size)))
        source.write_bytes(source_bytes)
        target.write_bytes(bytes(source_size))
        areas_file.write_text(payload, encoding="utf-8")
        os.chmod(areas_file, 0o600)

        subprocess.run(
            [
                sys.executable,
                str(PATCH_APPLY),
                "--source",
                str(source),
                "--target",
                str(target),
                "--areas-file",
                str(areas_file),
                "--coalesce-gap",
                "0",
                "--chunk",
                "4096",
            ],
            check=True,
        )

        target_bytes = target.read_bytes()
        for area in areas:
            start = area["offset"]
            end = start + area["length"]
            if target_bytes[start:end] != source_bytes[start:end]:
                raise AssertionError(f"changed area was not copied at offset {start}")
        if target_bytes[32:48] != bytes(16):
            raise AssertionError("unchanged area was unexpectedly overwritten")

        legacy_target = tmp / "legacy-target.raw"
        legacy_target.write_bytes(bytes(source_size))
        subprocess.run(
            [
                sys.executable,
                str(PATCH_APPLY),
                "--source",
                str(source),
                "--target",
                str(legacy_target),
                "--areas-json",
                '{"areas":[{"offset":0,"length":16}]}',
                "--coalesce-gap",
                "0",
                "--chunk",
                "4096",
            ],
            check=True,
        )
        if legacy_target.read_bytes()[:16] != source_bytes[:16]:
            raise AssertionError("legacy --areas-json compatibility path failed")

    transfer_source = TRANSFER_PATCH.read_text(encoding="utf-8")
    if '--areas-file "${areas_file}"' not in transfer_source:
        raise AssertionError("transfer path does not use --areas-file")
    if '--areas-json "${areas_json}"' in transfer_source:
        raise AssertionError("transfer path still passes CBT JSON through argv")

    print(
        "PASS: large CBT payload delivered by file "
        f"(areas={len(areas)}, bytes={len(payload.encode('utf-8'))})"
    )


if __name__ == "__main__":
    main()
