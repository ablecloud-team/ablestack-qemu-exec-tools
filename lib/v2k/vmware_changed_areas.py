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
#   { "disk_id": "...", "areas":[{"offset":..,"length":..},...]}
# ---------------------------------------------------------------------

import argparse
import json
import os
import ssl
import re
from urllib.parse import urlparse
from typing import Any, Dict, List, Tuple, Optional

from pyVim.connect import SmartConnect, Disconnect
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

    ctx = None
    if insecure:
        ctx = ssl._create_unverified_context()  # noqa: S501
    # NOTE: SmartConnect default path is "/sdk" but we allow override if VCENTER_HOST includes custom path.
    return SmartConnect(host=host, port=port, user=user, pwd=pw, sslContext=ctx, path=path)


def _find_vm(content: Any, name: str) -> vim.VirtualMachine:
    container = content.viewManager.CreateContainerView(content.rootFolder, [vim.VirtualMachine], True)
    try:
        for vm in container.view:
            if vm.name == name:
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
) -> List[Dict[str, int]]:
    """
    QueryChangedDiskAreas for a given snapshot and disk.

    IMPORTANT semantics:
      - This call returns changes relative to `change_id` within the CBT epoch.
      - If change_id="*", vSphere may return "sectors in use" or overly broad ranges,
        depending on CBT state. For incremental sync correctness you should persist and
        pass the previous changeId (per disk) from the last successful sync.
    """
    try:
        areas = vm.QueryChangedDiskAreas(snapshot=snap, deviceKey=disk.key, startOffset=0, changeId=change_id)
    except Exception as e:
        raise SystemExit(f"QueryChangedDiskAreas failed: {e}") from e

    out: List[Dict[str, int]] = []
    for a in areas.changedArea:
        out.append({"offset": int(a.start), "length": int(a.length)})
    # Attach changeId if present (vim.vm.DiskChangeInfo.changeId)
    return out, getattr(areas, "changeId", "") or ""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--vm", required=True)
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("--disk-id", required=True, help="Disk identifier like scsi0:0")
    ap.add_argument("--change-id", default="*", help="Previous CBT changeId for this disk (default: *)")
    args = ap.parse_args()

    si = _connect()
    try:
        content = si.RetrieveContent()
        vm = _find_vm(content, args.vm)
        snap = _find_snapshot_ref(vm, args.snapshot)
        devs = _devices_from_snapshot_or_vm(vm, snap)
        _, disk = _disk_for_scsi_in_devices(devs, args.disk_id)
        areas, areas_change_id = _query_changed_areas(vm, snap, disk, args.change_id)

        # Snapshot disk backing fileName (delta chain top like *_000002.vmdk)
        vmdk_path = ""
        try:
            vmdk_path = str(getattr(getattr(disk, "backing", None), "fileName", "") or "")
        except Exception:
            vmdk_path = ""

        # Prefer DiskChangeInfo.changeId; fallback to disk.backing.changeId
        new_change_id = str(areas_change_id or "") if areas_change_id else ""
        if not new_change_id:
            try:
                new_change_id = str(getattr(getattr(disk, "backing", None), "changeId", "") or "")
            except Exception:
                new_change_id = ""

        print(json.dumps({
            "disk_id": args.disk_id,
            "change_id": args.change_id,
            "new_change_id": new_change_id,
            "vmdk_path": vmdk_path,
            "areas": areas
        }))
    finally:
        Disconnect(si)

if __name__ == "__main__":
    main()
