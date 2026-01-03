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


def copy_region(src_fd, dst_fd, offset: int, length: int, chunk: int) -> None:
    remaining = length
    pos = offset
    while remaining > 0:
        n = chunk if remaining > chunk else remaining
        src_fd.seek(pos)
        buf = src_fd.read(n)
        if len(buf) != n:
            raise RuntimeError(f"short read at {pos}: expected {n}, got {len(buf)}")
        dst_fd.seek(pos)
        dst_fd.write(buf)
        remaining -= n
        pos += n


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--areas-json", required=True)
    ap.add_argument("--coalesce-gap", type=int, default=1024 * 1024)
    ap.add_argument("--chunk", type=int, default=4 * 1024 * 1024)
    args = ap.parse_args()

    areas_obj: Dict = json.loads(args.areas_json)
    areas = [(int(a["offset"]), int(a["length"])) for a in areas_obj.get("areas", [])]
    merged = coalesce(areas, args.coalesce_gap)

    if not os.path.exists(args.source):
        raise SystemExit(f"source not found: {args.source}")
    if not os.path.exists(args.target):
        raise SystemExit(f"target not found: {args.target}")

    with open(args.source, "rb", buffering=0) as src_fd, open(args.target, "r+b", buffering=0) as dst_fd:
        for off, ln in merged:
            copy_region(src_fd, dst_fd, off, ln, args.chunk)


if __name__ == "__main__":
    main()
