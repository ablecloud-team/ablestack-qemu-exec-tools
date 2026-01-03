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
from typing import Any, Dict, List, Tuple

from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim


def _connect() -> Any:
    host = os.environ.get("VCENTER_HOST", "")
    user = os.environ.get("VCENTER_USER", "")
    pw = os.environ.get("VCENTER_PASS", "")
    insecure = os.environ.get("VCENTER_INSECURE", "1") == "1"

    if not host or not user or not pw:
        raise SystemExit("Missing VCENTER_HOST/VCENTER_USER/VCENTER_PASS")

    ctx = None
    if insecure:
        ctx = ssl._create_unverified_context()  # noqa: S501
    return SmartConnect(host=host, user=user, pwd=pw, sslContext=ctx)


def _find_vm(content: Any, name: str) -> vim.VirtualMachine:
    container = content.viewManager.CreateContainerView(content.rootFolder, [vim.VirtualMachine], True)
    try:
        for vm in container.view:
            if vm.name == name:
                return vm
    finally:
        container.Destroy()
    raise SystemExit(f"VM not found: {name}")


def _find_snapshot(vm: vim.VirtualMachine, snap_name: str) -> vim.vm.Snapshot:
    tree = vm.snapshot.rootSnapshotList if vm.snapshot else []
    stack = list(tree)
    while stack:
        node = stack.pop()
        if node.name == snap_name:
            return node.snapshot
        stack.extend(node.childSnapshotList or [])
    raise SystemExit(f"Snapshot not found: {snap_name}")


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


def _query_changed_areas(vm: vim.VirtualMachine, snap: vim.vm.Snapshot, disk: vim.vm.device.VirtualDisk) -> List[Dict[str, int]]:
    # Use changeId="*" to query sectors in use is risky with CBT+snapshots.
    # Here we query since beginning of snapshot epoch by using startOffset=0 and changeId from snapshot is not trivial.
    # Practical approach:
    #   - Use changeId from previous sync. For v1, we return "all changed since snapshot" by calling with changeId="*"
    #     ONLY if VM had CBT enabled cleanly. This may fail in some CBT-epoch issues.
    #
    # For v1, we do:
    #   vm.QueryChangedDiskAreas(snapshot=snap, deviceKey=disk.key, startOffset=0, changeId="*")
    #
    # You will tune this in v2 with persisted changeId per disk.
    try:
        areas = vm.QueryChangedDiskAreas(snapshot=snap, deviceKey=disk.key, startOffset=0, changeId="*")
    except Exception as e:
        raise SystemExit(f"QueryChangedDiskAreas failed: {e}") from e

    out: List[Dict[str, int]] = []
    for a in areas.changedArea:
        out.append({"offset": int(a.start), "length": int(a.length)})
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--vm", required=True)
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("--disk-id", required=True)
    args = ap.parse_args()

    si = _connect()
    try:
        content = si.RetrieveContent()
        vm = _find_vm(content, args.vm)
        snap = _find_snapshot(vm, args.snapshot)
        _, disk = _disk_key_for_scsi(vm, args.disk_id)
        areas = _query_changed_areas(vm, snap, disk)
        print(json.dumps({"disk_id": args.disk_id, "areas": areas}))
    finally:
        Disconnect(si)


if __name__ == "__main__":
    main()
