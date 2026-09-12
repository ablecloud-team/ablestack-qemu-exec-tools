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
# ---------------------------------------------------------------------

import argparse
import fcntl
import json
import os
import struct
import sys
import tempfile
import time
from typing import Dict, Iterable, List


BLKGETSIZE64 = 0x80081272


def write_progress(path: str, payload: Dict[str, object]) -> None:
    if not path:
        return
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_progress_sequence(path: str) -> int:
    if not path:
        return 0
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
            return max(0, int(value.get("sampleSequence") or 0)) if isinstance(value, dict) else 0
    except (OSError, TypeError, ValueError):
        return 0


def parse_rbd_target(target: str):
    if not target.startswith("rbd:"):
        return None
    payload = target[4:]
    if ":" in payload or "/" not in payload:
        raise ValueError(f"unsupported RBD target URI: {target}")
    pool, image = payload.split("/", 1)
    if not pool or not image:
        raise ValueError(f"invalid RBD target URI: {target}")
    return pool, image


def device_size(fd: int) -> int:
    try:
        result = fcntl.ioctl(fd, BLKGETSIZE64, struct.pack("Q", 0))
        return int(struct.unpack("Q", result)[0])
    except OSError:
        return int(os.lseek(fd, 0, os.SEEK_END))


def normalize(areas: Iterable[Dict[str, int]], upper_bound: int) -> List[Dict[str, int]]:
    ordered = []
    for raw in areas:
        offset = int(raw.get("offset", -1))
        length = int(raw.get("length", -1))
        if offset < 0 or length < 0 or offset + length > upper_bound:
            raise ValueError(f"invalid CBT extent offset={offset} length={length} size={upper_bound}")
        if length:
            ordered.append((offset, offset + length))
    ordered.sort()
    merged: List[List[int]] = []
    for start, end in ordered:
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return [{"offset": start, "length": end - start} for start, end in merged]


def copy_extents(
    source: str,
    target: str,
    areas: List[Dict[str, int]],
    chunk: int,
    expected_source_size: int = 0,
    expected_target_size: int = 0,
    verify: bool = False,
    progress_json: str = "",
    progress_base_bytes: int = 0,
    progress_disk_index: int = 0,
    progress_total_bytes: int = 0,
    progress_disk_count: int = 1,
    progress_disk_label: str = "",
    progress_mode: str = "CBT_INCREMENTAL",
    progress_plan_uuid: str = "",
    progress_run_uuid: str = "",
    progress_cycle_sequence: int = 0,
    progress_final_disk: bool = False,
    bandwidth_limit_mbps: int = 0,
    progress_direction: str = "VMWARE_TO_KVM",
) -> Dict[str, int]:
    source_fd = os.open(source, os.O_RDONLY)
    target_fd = None
    cluster = None
    ioctx = None
    image = None
    started = time.monotonic_ns()
    bytes_read = 0
    bytes_written = 0
    verified_bytes = 0
    last_progress = 0.0
    sample_sequence = int(read_progress_sequence(progress_json))
    expected_payload_bytes = sum(max(0, int(item.get("length", 0))) for item in areas)
    aggregate_total_bytes = max(progress_total_bytes, progress_base_bytes + expected_payload_bytes)
    bandwidth_bytes_per_second = max(0, bandwidth_limit_mbps) * 1_000_000 / 8.0

    def throttle() -> None:
        if bandwidth_bytes_per_second <= 0 or bytes_read <= 0:
            return
        expected_elapsed = bytes_read / bandwidth_bytes_per_second
        actual_elapsed = (time.monotonic_ns() - started) / 1_000_000_000
        delay = expected_elapsed - actual_elapsed
        if delay > 0:
            time.sleep(delay)

    def publish_progress(state: str, force: bool = False) -> None:
        nonlocal last_progress, sample_sequence
        now = time.monotonic()
        if not force and now - last_progress < 2.0:
            return
        last_progress = now
        sample_sequence += 1
        processed = progress_base_bytes + bytes_read
        elapsed = max(0.001, (time.monotonic_ns() - started) / 1_000_000_000)
        throughput = max(0, int(bytes_read / elapsed))
        remaining = max(0, aggregate_total_bytes - processed)
        percent = (processed * 100.0 / aggregate_total_bytes) if aggregate_total_bytes > 0 else 0.0
        write_progress(progress_json, {
            "schemaVersion": 2,
            "planUuid": progress_plan_uuid,
            "runUuid": progress_run_uuid,
            "cycleSequence": progress_cycle_sequence,
            "sampleSequence": sample_sequence,
            "phase": "VERIFY" if state == "VERIFYING" else "TRANSFER",
            "state": state,
            "mode": progress_mode,
            "direction": progress_direction,
            "diskIndex": progress_disk_index,
            "diskCount": max(1, progress_disk_count),
            "diskLabel": progress_disk_label,
            "bytesTotal": aggregate_total_bytes,
            "bytesProcessed": processed,
            "sourceReadBytes": progress_base_bytes + bytes_read,
            "targetWrittenBytes": progress_base_bytes + bytes_written,
            "transferPayloadBytes": progress_base_bytes + bytes_read,
            "verifiedBytes": progress_base_bytes + verified_bytes if verify else 0,
            "percent": round(max(0.0, min(100.0, percent)), 2),
            "throughputBps": throughput,
            "etaSeconds": int(remaining / throughput) if throughput > 0 and remaining > 0 else 0,
            "progressEstimated": False,
            "updatedAtEpochMs": int(time.time() * 1000),
            "heartbeatAtEpochMs": int(time.time() * 1000),
        })
    try:
        source_size = device_size(source_fd)
        rbd_target = parse_rbd_target(target)
        if rbd_target:
            try:
                import rados
                import rbd
            except ImportError as error:
                raise RuntimeError("python-rados and python-rbd are required for an RBD target") from error
            cluster = rados.Rados(
                conffile=os.environ.get("FTCTL_DR_RBD_CONF", "/etc/ceph/ceph.conf"),
                rados_id=os.environ.get("FTCTL_DR_RBD_USER", "admin"),
            )
            cluster.connect()
            ioctx = cluster.open_ioctx(rbd_target[0])
            image = rbd.Image(ioctx, rbd_target[1])
            target_size = int(image.size())
        else:
            target_fd = os.open(target, os.O_RDWR)
            target_size = device_size(target_fd)
        if source_size <= 0 or target_size <= 0:
            raise ValueError(
                f"block device is not ready sourceSize={source_size} targetSize={target_size}"
            )
        if expected_source_size and source_size < expected_source_size:
            raise ValueError(
                f"source device is undersized expected={expected_source_size} actual={source_size}"
            )
        if expected_target_size and target_size < expected_target_size:
            raise ValueError(
                f"target device is undersized expected={expected_target_size} actual={target_size}"
            )
        upper_bound = min(source_size, target_size)
        normalized = normalize(areas, upper_bound)
        publish_progress("COPYING", True)
        for extent in normalized:
            offset = extent["offset"]
            remaining = extent["length"]
            while remaining:
                amount = min(remaining, chunk)
                data = os.pread(source_fd, amount, offset)
                if len(data) != amount:
                    raise IOError(f"short source read at {offset}: expected={amount} actual={len(data)}")
                bytes_read += len(data)
                throttle()
                if image is not None:
                    image.write(data, offset)
                    bytes_written += len(data)
                else:
                    written = 0
                    while written < len(data):
                        count = os.pwrite(target_fd, data[written:], offset + written)
                        if count <= 0:
                            raise IOError(f"short target write at {offset + written}")
                        written += count
                        bytes_written += count
                offset += amount
                remaining -= amount
                publish_progress("COPYING")
        if image is not None:
            image.flush()
        else:
            os.fsync(target_fd)
        if verify:
            for extent in normalized:
                offset = extent["offset"]
                remaining = extent["length"]
                while remaining:
                    amount = min(remaining, chunk)
                    source_data = os.pread(source_fd, amount, offset)
                    if image is not None:
                        target_data = image.read(offset, amount)
                    else:
                        target_data = os.pread(target_fd, amount, offset)
                    if source_data != target_data:
                        raise IOError(f"target verification failed at offset={offset} length={amount}")
                    verified_bytes += amount
                    offset += amount
                    remaining -= amount
                    publish_progress("VERIFYING")
        duration_ms = max(1, (time.monotonic_ns() - started) // 1_000_000)
        publish_progress("COMPLETE" if progress_final_disk else "COPYING", True)
        return {
            "changedExtentCount": len(normalized),
            "changedBytes": sum(item["length"] for item in normalized),
            "sourceReadBytes": bytes_read,
            "targetWrittenBytes": bytes_written,
            "transferPayloadBytes": bytes_read,
            "durationMs": duration_ms,
            "throughputBps": (bytes_read * 1000) // duration_ms,
            "writeVerified": bool(verify),
            "verifiedBytes": verified_bytes,
            "bandwidthLimitMbps": max(0, bandwidth_limit_mbps),
        }
    finally:
        if image is not None:
            image.close()
        if ioctx is not None:
            ioctx.close()
        if cluster is not None:
            cluster.shutdown()
        if target_fd is not None:
            os.close(target_fd)
        os.close(source_fd)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--areas-json", required=True)
    parser.add_argument("--chunk", type=int, default=8 * 1024 * 1024)
    parser.add_argument("--expected-source-size", type=int, default=0)
    parser.add_argument("--expected-target-size", type=int, default=0)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--progress-json", default="")
    parser.add_argument("--progress-base-bytes", type=int, default=0)
    parser.add_argument("--progress-disk-index", type=int, default=0)
    parser.add_argument("--progress-total-bytes", type=int, default=0)
    parser.add_argument("--progress-disk-count", type=int, default=1)
    parser.add_argument("--progress-disk-label", default="")
    parser.add_argument("--progress-mode", default="CBT_INCREMENTAL")
    parser.add_argument("--progress-direction", default="VMWARE_TO_KVM")
    parser.add_argument("--progress-plan-uuid", default="")
    parser.add_argument("--progress-run-uuid", default="")
    parser.add_argument("--progress-cycle-sequence", type=int, default=0)
    parser.add_argument("--progress-final-disk", action="store_true")
    parser.add_argument("--bandwidth-limit-mbps", type=int, default=0)
    args = parser.parse_args()
    with open(args.areas_json, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    result = copy_extents(
        args.source,
        args.target,
        payload.get("areas") or [],
        max(4096, args.chunk),
        max(0, args.expected_source_size),
        max(0, args.expected_target_size),
        args.verify,
        args.progress_json,
        max(0, args.progress_base_bytes),
        max(0, args.progress_disk_index),
        max(0, args.progress_total_bytes),
        max(1, args.progress_disk_count),
        args.progress_disk_label,
        args.progress_mode,
        args.progress_plan_uuid,
        args.progress_run_uuid,
        max(0, args.progress_cycle_sequence),
        args.progress_final_disk,
        max(0, args.bandwidth_limit_mbps),
        args.progress_direction,
    )
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"DR_CBT_PATCH_FAILED: {error}", file=sys.stderr)
        sys.exit(86)
