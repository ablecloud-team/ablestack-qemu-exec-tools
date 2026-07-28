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
# Purpose:
#   QueryChangedDiskAreas for a given VM snapshot + disk_id (scsiX:Y)
#
# Inputs:
#   --vm <name>
#   --snapshot <snapshot name>
#   --disk-id <scsiX:Y>
#   [--change-id <prev changeId>]
#
# Env:
#   VCENTER_HOST (like https://vcenter/sdk or vcenter fqdn)
#   VCENTER_USER
#   VCENTER_PASS
#   VCENTER_INSECURE (1/0)
#
# Output(JSON):
#   {
#     "disk_id": "...",
#     "coverage": {
#       "complete": true,
#       "start_offset": 0,
#       "end_offset": 1073741824,
#       "disk_capacity": 1073741824,
#       "pages": 2
#     },
#     "areas":[{"offset":..,"length":..},...]
#   }
# ---------------------------------------------------------------------

import argparse
import json
import os
import ssl
import re
import sys
from urllib.parse import urlparse
from typing import Any, Dict, List, Tuple, Optional

from pyVim.connect import SmartConnect, Disconnect
try:
    from pyVim.connect import SmartConnectNoSSL
except ImportError:  # pyVmomi versions can differ across compatibility profiles.
    SmartConnectNoSSL = None
from pyVmomi import vim


def _parse_vcenter_target(raw: str) -> Tuple[str, int, str]:
    """
    Accepts:
      - "10.10.21.10"
      - "vcenter.example.local"
      - "https://10.10.21.10/sdk"
      - "http://vcenter/sdk"
      - "10.10.21.10:443"
    Returns: (host, port, path)
    """
    s = (raw or "").strip()
    if not s:
        return ("", 0, "/sdk")

    # If scheme exists, parse as URL
    if "://" in s:
        u = urlparse(s)
        host = u.hostname or ""
        port = int(u.port or (443 if (u.scheme or "").lower() == "https" else 80))
        path = u.path or "/sdk"
        if not path.startswith("/"):
            path = "/" + path
        # vSphere SOAP endpoint path typically "/sdk"
        return (host, port, path)

    # host:port
    m = re.match(r"^\[?([0-9a-fA-F:.]+)\]?:([0-9]+)$", s)  # IPv6 or IPv4 with port
    if m:
        host = m.group(1)
        port = int(m.group(2))
        return (host, port, "/sdk")

    # Plain host or IP
    return (s, 443, "/sdk")


def _disable_default_ssl_verification() -> None:
    """
    Older pyVmomi releases do not accept sslContext and eventually fall back to
    Python's default HTTPS context.  On Python 3 that verifies certificates by
    default, so make VCENTER_INSECURE=1 effective for those old code paths too.
    """
    try:
        ssl._create_default_https_context = ssl._create_unverified_context  # type: ignore[attr-defined]  # noqa: S501
    except Exception:
        pass


def _connect() -> Any:
    raw = os.environ.get("VCENTER_HOST", "")
    user = os.environ.get("VCENTER_USER", "")
    pw = os.environ.get("VCENTER_PASS", "")
    insecure = os.environ.get("VCENTER_INSECURE", "1") == "1"

    if not raw or not user or not pw:
        raise SystemExit("Missing VCENTER_HOST/VCENTER_USER/VCENTER_PASS")

    host, port, path = _parse_vcenter_target(raw)
    if not host:
        raise SystemExit(f"Invalid VCENTER_HOST: {raw}")

    # NOTE: SmartConnect default path is "/sdk" but we allow override if VCENTER_HOST includes custom path.
    # Older pyVmomi releases used for ESXi/vCenter 5.5 do not accept sslContext.
    if insecure:
        _disable_default_ssl_verification()
        ctx = ssl._create_unverified_context()  # noqa: S501
        try:
            return SmartConnect(host=host, port=port, user=user, pwd=pw, sslContext=ctx, path=path)
        except TypeError as exc:
            msg = str(exc)
            if "sslContext" not in msg and "path" not in msg:
                raise
            if SmartConnectNoSSL is not None:
                try:
                    return SmartConnectNoSSL(host=host, port=port, user=user, pwd=pw, path=path)
                except TypeError as no_ssl_exc:
                    if "path" not in str(no_ssl_exc):
                        raise
                    return SmartConnectNoSSL(host=host, port=port, user=user, pwd=pw)
            try:
                return SmartConnect(host=host, port=port, user=user, pwd=pw, path=path)
            except TypeError as path_exc:
                if "path" not in str(path_exc):
                    raise
                return SmartConnect(host=host, port=port, user=user, pwd=pw)

    try:
        return SmartConnect(host=host, port=port, user=user, pwd=pw, path=path)
    except TypeError as exc:
        if "path" not in str(exc):
            raise
        return SmartConnect(host=host, port=port, user=user, pwd=pw)


def _find_vm(content: Any, name: str) -> vim.VirtualMachine:
    requested = (name or "").strip()
    fallback_name = requested.rsplit("/", 1)[-1] if "/" in requested else requested
    container = content.viewManager.CreateContainerView(content.rootFolder, [vim.VirtualMachine], True)
    try:
        for vm in container.view:
            moid = str(getattr(vm, "_moId", "") or "")
            if vm.name == requested or vm.name == fallback_name or moid == requested:
                return vm
    finally:
        container.Destroy()
    raise SystemExit(f"VM not found: {name}")


def _find_snapshot_ref(vm: vim.VirtualMachine, snap_name: str) -> vim.VirtualMachineSnapshot:
    tree = vm.snapshot.rootSnapshotList if vm.snapshot else []
    stack = list(tree)
    while stack:
        node = stack.pop()
        if node.name == snap_name:
            return node.snapshot
        stack.extend(node.childSnapshotList or [])
    raise SystemExit(f"Snapshot not found: {snap_name}")

 
def _snapshot_config(snapshot_ref: vim.VirtualMachineSnapshot) -> Optional[vim.vm.ConfigInfo]:
    try:
        return getattr(snapshot_ref, "config", None)
    except Exception:
        return None

def _disk_from_config_for_scsi(cfg: vim.vm.ConfigInfo, disk_id: str) -> Tuple[int, vim.vm.device.VirtualDisk]:
    m = re.match(r"^scsi(\d+):(\d+)$", disk_id)
    if not m:
        raise SystemExit(f"Unsupported disk-id format: {disk_id}")
    bus = int(m.group(1))
    unit = int(m.group(2))

    devices = list(getattr(getattr(cfg, "hardware", None), "device", []) or [])
    ctrl_bus: Dict[int, int] = {}
    for dev in devices:
        if isinstance(dev, vim.vm.device.VirtualSCSIController):
            ctrl_bus[int(dev.key)] = int(getattr(dev, "busNumber", 0))

    for dev in devices:
        if isinstance(dev, vim.vm.device.VirtualDisk):
            ck = int(dev.controllerKey)
            if ck in ctrl_bus and ctrl_bus[ck] == bus and int(dev.unitNumber) == unit:
                return int(dev.key), dev
    raise SystemExit(f"VirtualDisk not found for {disk_id} in snapshot config")


def _devices_from_snapshot_or_vm(vm: vim.VirtualMachine, snap: vim.vm.Snapshot):
    """
    Prefer snapshot-config devices to resolve the correct backing fileName for the snapshot chain.
    Fallback to vm.config if snapshot.config is unavailable.
    """
    try:
        cfg = getattr(snap, "config", None)
        hw = getattr(cfg, "hardware", None) if cfg else None
        devs = getattr(hw, "device", None) if hw else None
        if devs:
            return devs
    except Exception:
        pass
    return vm.config.hardware.device


def _disk_key_for_scsi(vm: vim.VirtualMachine, disk_id: str) -> Tuple[int, vim.vm.device.VirtualDisk]:
    # disk_id: scsi<bus>:<unit>
    import re
    m = re.match(r"^scsi(\d+):(\d+)$", disk_id)
    if not m:
        raise SystemExit(f"Unsupported disk-id format: {disk_id}")
    bus = int(m.group(1))
    unit = int(m.group(2))

    # Map controllerKey -> busNumber
    ctrl_bus: Dict[int, int] = {}
    for dev in vm.config.hardware.device:
        if isinstance(dev, vim.vm.device.VirtualSCSIController):
            ctrl_bus[int(dev.key)] = int(getattr(dev, "busNumber", 0))

    for dev in vm.config.hardware.device:
        if isinstance(dev, vim.vm.device.VirtualDisk):
            ck = int(dev.controllerKey)
            if ck in ctrl_bus and ctrl_bus[ck] == bus and int(dev.unitNumber) == unit:
                return int(dev.key), dev
    raise SystemExit(f"VirtualDisk not found for {disk_id}")


def _disk_for_scsi_in_devices(devices, disk_id: str) -> Tuple[int, vim.vm.device.VirtualDisk]:
    m = re.match(r"^scsi(\d+):(\d+)$", disk_id)
    if not m:
        raise SystemExit(f"Unsupported disk-id format: {disk_id}")
    bus = int(m.group(1))
    unit = int(m.group(2))

    ctrl_bus: Dict[int, int] = {}
    for dev in devices:
        if isinstance(dev, vim.vm.device.VirtualSCSIController):
            ctrl_bus[int(dev.key)] = int(getattr(dev, "busNumber", 0))

    for dev in devices:
        if isinstance(dev, vim.vm.device.VirtualDisk):
            ck = int(dev.controllerKey)
            if ck in ctrl_bus and ctrl_bus[ck] == bus and int(dev.unitNumber) == unit:
                return int(dev.key), dev
    raise SystemExit(f"VirtualDisk not found for {disk_id} in snapshot/vm devices")


def _query_changed_areas(
    vm: vim.VirtualMachine,
    snap: vim.vm.Snapshot,
    disk: vim.vm.device.VirtualDisk,
    change_id: str,
) -> Tuple[List[Dict[str, int]], str, Dict[str, Any]]:
    """
    QueryChangedDiskAreas for a given snapshot and disk.

    IMPORTANT semantics:
      - This call returns changes relative to `change_id` within the CBT epoch.
      - If change_id="*", vSphere may return "sectors in use" or overly broad ranges,
        depending on CBT state. For incremental sync correctness you should persist and
        pass the previous changeId (per disk) from the last successful sync.
    """
    capacity = int(getattr(disk, "capacityInBytes", 0) or 0)
    if capacity <= 0:
        capacity_kb = int(getattr(disk, "capacityInKB", 0) or 0)
        capacity = capacity_kb * 1024
    if capacity <= 0:
        raise SystemExit("QueryChangedDiskAreas cannot validate coverage: disk capacity is unavailable")

    out: List[Dict[str, int]] = []
    seen_extents = set()
    next_offset = 0
    page_count = 0
    query_change_id = ""

    while next_offset < capacity:
        requested_offset = next_offset
        try:
            page = vm.QueryChangedDiskAreas(
                snapshot=snap,
                deviceKey=disk.key,
                startOffset=requested_offset,
                changeId=change_id,
            )
        except Exception as e:
            raise SystemExit(
                f"QueryChangedDiskAreas failed at offset {requested_offset}: {e}"
            ) from e

        page_start = int(getattr(page, "startOffset", -1))
        page_length = int(getattr(page, "length", 0))
        page_end = page_start + page_length
        if page_start != requested_offset:
            raise SystemExit(
                "QueryChangedDiskAreas returned non-contiguous coverage: "
                f"requested={requested_offset}, returned_start={page_start}"
            )
        if page_length <= 0 or page_end <= requested_offset:
            raise SystemExit(
                "QueryChangedDiskAreas made no coverage progress: "
                f"start={page_start}, length={page_length}, capacity={capacity}"
            )
        if page_end > capacity:
            raise SystemExit(
                "QueryChangedDiskAreas coverage exceeds disk capacity: "
                f"end={page_end}, capacity={capacity}"
            )

        page_count += 1
        page_change_id = str(getattr(page, "changeId", "") or "")
        if page_change_id:
            if query_change_id and query_change_id != page_change_id:
                raise SystemExit(
                    "QueryChangedDiskAreas returned inconsistent changeId values "
                    f"across pages: {query_change_id} != {page_change_id}"
                )
            query_change_id = page_change_id

        for area in list(getattr(page, "changedArea", []) or []):
            offset = int(area.start)
            length = int(area.length)
            end = offset + length
            if length <= 0:
                raise SystemExit(
                    f"QueryChangedDiskAreas returned a non-positive extent at {offset}: {length}"
                )
            if offset < page_start or end > page_end or end > capacity:
                raise SystemExit(
                    "QueryChangedDiskAreas returned an extent outside its coverage page: "
                    f"extent={offset}+{length}, page={page_start}+{page_length}, capacity={capacity}"
                )
            extent = (offset, length)
            if extent not in seen_extents:
                seen_extents.add(extent)
                out.append({"offset": offset, "length": length})

        next_offset = page_end

    coverage: Dict[str, Any] = {
        "mode": "delta",
        "complete": next_offset == capacity,
        "start_offset": 0,
        "end_offset": next_offset,
        "disk_capacity": capacity,
        "pages": page_count,
    }
    if not coverage["complete"]:
        raise SystemExit(
            "QueryChangedDiskAreas coverage is incomplete: "
            f"end={next_offset}, capacity={capacity}, pages={page_count}"
        )
    return out, query_change_id, coverage

 
def _disk_backing_vmdk_path(disk: vim.vm.device.VirtualDisk) -> str:
    try:
        return str(getattr(getattr(disk, "backing", None), "fileName", "") or "")
    except Exception:
        return ""


def _disk_backing_change_id(disk: vim.vm.device.VirtualDisk) -> str:
    try:
        return str(getattr(getattr(disk, "backing", None), "changeId", "") or "")
    except Exception:
        return ""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--vm", required=True)
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("--disk-id", required=True, help="Disk identifier like scsi0:0")
    # NOTE:
    # - transfer_patch.sh will now enforce that incremental/final patch must have a valid change-id.
    # - We still keep this tool defensive: if change-id is "*" or empty, return empty areas to avoid
    #   accidental full-disk diffs.
    ap.add_argument("--change-id", default="", help="Previous CBT changeId for this disk (empty means unset)")

    args = ap.parse_args()

    si = _connect()
    try:
        content = si.RetrieveContent()
        vm = _find_vm(content, args.vm)
        snap = _find_snapshot_ref(vm, args.snapshot)
        devs = _devices_from_snapshot_or_vm(vm, snap)
        _, disk = _disk_for_scsi_in_devices(devs, args.disk_id)

        # IMPORTANT SAFETY:
        # - "*" (and empty) are often used as placeholders when we couldn't persist a
        #   real CBT changeId yet.
        # - Passing "*" into QueryChangedDiskAreas can be interpreted as "from the beginning"
        #   on some vSphere builds, returning a full-disk diff (=> incremental becomes full read).
        #
        # Policy:
        # - If change_id is "*" or empty, DO NOT query changed areas.
        # - Just report empty areas and advance new_change_id to the current one.
        effective_change_id = (args.change_id or "").strip()
        if effective_change_id in ("", "null", "*"):
            vmdk_path = _disk_backing_vmdk_path(disk)
            change_id_source = "snapshot"
            cur = _disk_backing_change_id(disk) or ""
            capacity = int(getattr(disk, "capacityInBytes", 0) or 0)
            if capacity <= 0:
                capacity = int(getattr(disk, "capacityInKB", 0) or 0) * 1024
            if capacity <= 0:
                raise SystemExit("Cannot establish CBT baseline: disk capacity is unavailable")
            if not cur:
                try:
                    _, current_disk = _disk_key_for_scsi(vm, args.disk_id)
                    cur = _disk_backing_change_id(current_disk) or ""
                    if cur:
                        change_id_source = "current"
                except Exception as exc:
                    sys.stderr.write(f"WARN: failed to read current backing changeId for {args.disk_id}: {exc}\n")
            result = {
                "disk_id": args.disk_id,
                "snapshot": args.snapshot,
                "start_change_id": effective_change_id,
                "change_id": effective_change_id,
                "new_change_id": cur,
                "change_id_source": change_id_source,
                "vmdk_path": vmdk_path,
                "coverage": {
                    "mode": "baseline",
                    "complete": True,
                    "start_offset": 0,
                    "end_offset": capacity,
                    "disk_capacity": capacity,
                    "pages": 0,
                },
                "areas": [],
            }
            print(json.dumps(result, ensure_ascii=False))
            return

        areas, areas_change_id, coverage = _query_changed_areas(
            vm, snap, disk, effective_change_id
        )

        # Snapshot disk backing fileName (delta chain top like *_000002.vmdk)
        vmdk_path = _disk_backing_vmdk_path(disk)

        # Prefer DiskChangeInfo.changeId; fallback to disk.backing.changeId
        new_change_id = str(areas_change_id or "") if areas_change_id else ""
        change_id_source = "query"
        if not new_change_id:
            new_change_id = _disk_backing_change_id(disk) or ""
            change_id_source = "snapshot"
        if not new_change_id:
            try:
                _, current_disk = _disk_key_for_scsi(vm, args.disk_id)
                new_change_id = _disk_backing_change_id(current_disk) or ""
                if new_change_id:
                    change_id_source = "current"
            except Exception as exc:
                sys.stderr.write(f"WARN: failed to read current backing changeId for {args.disk_id}: {exc}\n")

        # Debug logging
        sys.stderr.write(
            "DEBUG: Queried "
            f"{len(areas)} changed areas across {coverage['pages']} pages "
            f"for disk {args.disk_id}, coverage="
            f"{coverage['end_offset']}/{coverage['disk_capacity']}, "
            f"change_id={effective_change_id}\n"
        )

        print(json.dumps({
            "disk_id": args.disk_id,
            "change_id": effective_change_id,
            "new_change_id": new_change_id,
            "change_id_source": change_id_source,
            "vmdk_path": vmdk_path,
            "coverage": coverage,
            "areas": areas
        }))
    finally:
        Disconnect(si)

if __name__ == "__main__":
    main()
