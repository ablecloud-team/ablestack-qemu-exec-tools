#!/usr/bin/env python3
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Apply changed areas from source image to target image.
# - areas are coalesced (merge) with --coalesce-gap
# - each merged region is copied in chunks (--chunk)
# ---------------------------------------------------------------------

import argparse
import json
import os
import subprocess
from typing import Dict, List, Tuple


def coalesce(areas: List[Tuple[int, int]], gap: int) -> List[Tuple[int, int]]:
    if not areas:
        return []
    areas = sorted(areas, key=lambda x: x[0])
    merged: List[Tuple[int, int]] = []
    cur_s, cur_l = areas[0]
    cur_e = cur_s + cur_l

    for s, l in areas[1:]:
        e = s + l
        if s <= cur_e + gap:
            cur_e = max(cur_e, e)
        else:
            merged.append((cur_s, cur_e - cur_s))
            cur_s, cur_e = s, e
    merged.append((cur_s, cur_e - cur_s))
    return merged


def discard_range(target: str, offset: int, length: int) -> bool:
    if length <= 0:
        return True
    try:
        result = subprocess.run(
            ["blkdiscard", "-o", str(offset), "-l", str(length), target],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0
    except FileNotFoundError:
        return False


def load_areas(areas_file: str, areas_json: str) -> Dict:
    if areas_file:
        try:
            with open(areas_file, "r", encoding="utf-8") as areas_fd:
                areas_obj = json.load(areas_fd)
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise SystemExit(f"failed to read areas file {areas_file}: {exc}") from exc
    else:
        try:
            areas_obj = json.loads(areas_json)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"failed to parse areas JSON: {exc}") from exc

    if not isinstance(areas_obj, dict):
        raise SystemExit("changed areas payload must be a JSON object")
    return areas_obj


def copy_region(src_fd, dst_fd, target: str, offset: int, length: int, chunk: int, sparse_zero: bool) -> Tuple[int, int]:
    remaining = length
    pos = offset
    discarded = 0
    discard_failed = 0
    while remaining > 0:
        n = chunk if remaining > chunk else remaining
        src_fd.seek(pos)
        buf = src_fd.read(n)
        if len(buf) != n:
            raise RuntimeError(f"short read at {pos}: expected {n}, got {len(buf)}")
        if sparse_zero and not any(buf):
            if discard_range(target, pos, n):
                discarded += 1
                remaining -= n
                pos += n
                continue
            discard_failed += 1
        dst_fd.seek(pos)
        dst_fd.write(buf)
        remaining -= n
        pos += n
    return discarded, discard_failed


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    ap.add_argument("--target", required=True)
    areas_input = ap.add_mutually_exclusive_group(required=True)
    areas_input.add_argument(
        "--areas-file",
        help="UTF-8 JSON file containing changed areas (recommended for large payloads)",
    )
    areas_input.add_argument(
        "--areas-json",
        help="inline changed areas JSON (legacy compatibility only)",
    )
    ap.add_argument("--coalesce-gap", type=int, default=1024 * 1024)
    ap.add_argument("--chunk", type=int, default=4 * 1024 * 1024)
    ap.add_argument("--target-kind", default="")
    ap.add_argument("--sparse-zero", choices=("on", "off"), default="off")
    args = ap.parse_args()

    areas_obj = load_areas(args.areas_file, args.areas_json)
    areas = [(int(a["offset"]), int(a["length"])) for a in areas_obj.get("areas", [])]
    merged = coalesce(areas, args.coalesce_gap)

    if not os.path.exists(args.source):
        raise SystemExit(f"source not found: {args.source}")
    if not os.path.exists(args.target):
        raise SystemExit(f"target not found: {args.target}")

    sparse_zero = args.sparse_zero == "on" and args.target_kind == "rbd"
    total_discarded = 0
    total_discard_failed = 0

    with open(args.source, "rb", buffering=0) as src_fd, open(args.target, "r+b", buffering=0) as dst_fd:
        for off, ln in merged:
            discarded, discard_failed = copy_region(src_fd, dst_fd, args.target, off, ln, args.chunk, sparse_zero)
            total_discarded += discarded
            total_discard_failed += discard_failed

        # Ensure data reaches the underlying block device before disconnect
        try:
            dst_fd.flush()
            os.fsync(dst_fd.fileno())
        except Exception:
            pass
    if sparse_zero:
        print(
            json.dumps(
                {
                    "event": "sparse_zero_summary",
                    "discarded_chunks": total_discarded,
                    "discard_fallback_chunks": total_discard_failed,
                },
                separators=(",", ":"),
            )
        )

if __name__ == "__main__":
    main()
