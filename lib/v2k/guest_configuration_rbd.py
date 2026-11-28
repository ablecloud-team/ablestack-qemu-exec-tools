#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Private, pre-handoff RBD identities and owned kernel RBD mappings."""
import argparse
import contextlib
import fcntl
import hashlib
import stat
import json
import os
from pathlib import Path
import re
import subprocess
import time

OWNER_KEY = "ablecloud.migration.owner.v1"


def unsealed(m):
    cp = m.get("runtime", {}).get("cloud", {}).get("checkpoint", {})
    if (cp.get("root_volume_id") or cp.get("root_import_job_id") or cp.get("deploy_job_id")
            or cp.get("vm_id") or cp.get("data_volumes")
            or any(d.get("transfer", {}).get("cloud_allocation", {}).get("request_id") for d in m["disks"])):
        raise ValueError("CLOUD_TARGET_SEALED")


def spec(uri):
    if not re.fullmatch(r"rbd:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", uri):
        raise ValueError("RBD_PREPARATION_URI_UNSUPPORTED")
    if any(x in [".", ".."] for x in uri[4:].split("/")):
        raise ValueError("RBD_PREPARATION_URI_UNSUPPORTED")
    return uri[4:]


def rbd(*args):
    r = subprocess.run(["rbd", *args], capture_output=True, text=True, timeout=45)
    if r.returncode:
        raise ValueError("RBD_PREPARATION_COMMAND_FAILED")
    return r.stdout.strip()


def identity(m, index):
    unsealed(m)
    disk = m["disks"][index]
    uri = disk["transfer"]["target_path"]
    info = json.loads(rbd("info", spec(uri), "--format", "json"))
    if not isinstance(info.get("id"), str) or not info["id"] or info.get("size") != disk["size_bytes"]:
        raise ValueError("RBD_PREPARATION_IDENTITY_MISMATCH")
    run = m.get("run", {}).get("run_id")
    source = m["source"]["vm"].get("uuid")
    if not run or not source or not disk.get("disk_id"):
        raise ValueError("RBD_PREPARATION_OWNER_REQUIRED")
    return {"version": 1, "run_id": run, "source_vm_uuid": source,
            "source_disk_id": disk["disk_id"], "uri": uri,
            "image_id": info["id"], "size_bytes": info["size"], "scope": "pre-handoff-only"}


def record(manifest, index):
    from guest_configuration import atomic, canonical
    path = Path(manifest)
    m = json.loads(path.read_text())
    value = identity(m, index)
    image = spec(value["uri"])
    previous = subprocess.run(["rbd", "image-meta", "get", image, OWNER_KEY], capture_output=True, text=True, timeout=45)
    if previous.returncode == 0 and json.loads(previous.stdout) != value:
        raise ValueError("RBD_PREPARATION_OWNERSHIP_CONFLICT")
    if previous.returncode not in (0, 2):
        raise ValueError("RBD_PREPARATION_COMMAND_FAILED")
    if previous.returncode == 2:
        # Called only after the transfer's no-overwrite staging publish succeeded.
        rbd("image-meta", "set", image, OWNER_KEY, canonical(value))
    if json.loads(rbd("image-meta", "get", image, OWNER_KEY)) != value:
        raise ValueError("RBD_PREPARATION_OWNERSHIP_CONFLICT")
    m["disks"][index]["transfer"]["rbd_image"] = value
    atomic(path, m)


def verify_identity(m, index):
    expected = m["disks"][index].get("transfer", {}).get("rbd_image")
    if not expected or not m["disks"][index]["transfer"].get("base_done"):
        raise ValueError("RBD_PREPARATION_OWNERSHIP_REQUIRED")
    actual = identity(m, index)
    if actual != expected or json.loads(rbd("image-meta", "get", spec(actual["uri"]), OWNER_KEY)) != expected:
        raise ValueError("RBD_PREPARATION_OWNERSHIP_CONFLICT")
    return actual


class Mapping:
    def __init__(self, manifest, index, readonly=True):
        self.m, self.index, self.readonly = manifest, index, readonly
        self.device = None
        self.lock = None

    def __enter__(self):
        value = verify_identity(self.m, self.index)
        image = spec(value["uri"])
        lockdir = Path("/var/lock/ablestack-rbd-preparation")
        lockdir.mkdir(mode=0o700, exist_ok=True)
        self.lock = (lockdir / (hashlib.sha256(image.encode()).hexdigest() + ".lock")).open("a")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            status = json.loads(rbd("status", image, "--format", "json"))
            if status.get("watchers") or self._matching_mappings(image):
                raise ValueError("RBD_PREPARATION_IMAGE_BUSY")
            args = ["map", image]
            if self.readonly:
                args.append("--read-only")
            device = rbd(*args).strip()
            # Never accept or release a pre-existing mapping.
            if not re.fullmatch(r"/dev/rbd[0-9]+", device):
                raise ValueError("RBD_PREPARATION_MAPPING_INVALID")
            self.device = device
            subprocess.run(["udevadm", "settle"], check=True, timeout=30)
            if not stat.S_ISBLK(os.stat(device).st_mode):
                raise ValueError("RBD_PREPARATION_MAPPING_INVALID")
            mappings = self._matching_mappings(image)
            if len(mappings) != 1 or mappings[0]["device"] != device:
                raise ValueError("RBD_PREPARATION_MAPPING_CONFLICT")
            sysfs = Path("/sys/bus/rbd/devices") / Path(device).name[3:]
            if (sysfs / "image_id").read_text().strip() != value["image_id"]:
                raise ValueError("RBD_PREPARATION_MAPPING_IDENTITY_MISMATCH")
            size = int(subprocess.check_output(["blockdev", "--getsize64", device], text=True))
            ro = int(subprocess.check_output(["blockdev", "--getro", device], text=True))
            if size != value["size_bytes"] or ro != int(self.readonly):
                raise ValueError("RBD_PREPARATION_MAPPING_INVALID")
            if identity(self.m, self.index) != value:
                raise ValueError("RBD_PREPARATION_IDENTITY_MISMATCH")
            return device
        except BaseException as error:
            self.__exit__(type(error), error, error.__traceback__)
            raise

    @staticmethod
    def _matching_mappings(image):
        pool, name = image.split("/")
        values = json.loads(rbd("showmapped", "--format", "json"))
        values = values.values() if isinstance(values, dict) else values
        return [v for v in values if v.get("pool") == pool and v.get("name") == name and not v.get("namespace")]

    def __exit__(self, exc_type=None, exc=None, traceback=None):
        failure = None
        try:
            if self.device is not None:
                if not self.readonly:
                    try:
                        subprocess.run(["blockdev", "--flushbufs", self.device], check=True, timeout=30)
                    except (OSError, subprocess.SubprocessError) as error:
                        failure = error
                # A helper's QEMU process can take a moment to release its fd.
                # Never force an unmap or release any mapping we did not create.
                for attempt in range(5):
                    try:
                        rbd("unmap", self.device)
                        self.device = None
                        break
                    except (ValueError, OSError, subprocess.SubprocessError) as error:
                        if attempt == 4:
                            failure = failure or error
                        else:
                            time.sleep(1)
        finally:
            if self.lock is not None:
                self.lock.close()
                self.lock = None
        if failure is not None and exc_type is None:
            raise failure


def access_path(m, index, readonly=True):
    if m["target"]["storage"]["type"] == "rbd":
        return Mapping(m, index, readonly)
    return contextlib.nullcontext(m["disks"][index]["transfer"]["target_path"])


def winpe_mappings(manifest, action):
    """The caller holds every image lease and confirms its WinPE VM is stopped."""
    from guest_configuration import atomic
    path = Path(manifest)
    m = json.loads(path.read_text())
    unsealed(m)
    receipts = m.get('runtime', {}).get('winpe_krbd_mappings', [])
    if action == 'winpe-release':
        for row in receipts:
            value = verify_identity(m, row['index'])
            if row['image'] != value:
                raise ValueError('RBD_PREPARATION_OWNERSHIP_CONFLICT')
            image = spec(value['uri'])
            mappings = Mapping._matching_mappings(image)
            if not mappings:
                continue  # A previous release may have stopped part way through.
            device = row['device']
            if len(mappings) != 1 or mappings[0]['device'] != device:
                raise ValueError('RBD_PREPARATION_MAPPING_CONFLICT')
            kernel = Path('/sys/bus/rbd/devices') / Path(device).name[3:]
            if (kernel / 'image_id').read_text().strip() != value['image_id']:
                raise ValueError('RBD_PREPARATION_MAPPING_IDENTITY_MISMATCH')
            subprocess.run(['blockdev', '--flushbufs', device], check=True, timeout=30)
            rbd('unmap', device)  # Never force unmap of a device still in use.
        m.setdefault('runtime', {})['winpe_krbd_mappings'] = []
        atomic(path, m)
        return
    rows = []
    for index in range(len(m['disks'])):
        value = verify_identity(m, index)
        image = spec(value['uri'])
        mappings = Mapping._matching_mappings(image)
        if action == 'winpe-idle':
            if mappings or json.loads(rbd('status', image, '--format', 'json')).get('watchers'):
                raise ValueError('RBD_PREPARATION_IMAGE_BUSY')
        else:
            if not mappings:
                continue  # Record an owned partial mapping after a failed map.
            if len(mappings) != 1 or not re.fullmatch(r'/dev/rbd[0-9]+', mappings[0]['device']):
                raise ValueError('RBD_PREPARATION_MAPPING_INVALID')
            device = mappings[0]['device']
            kernel = Path('/sys/bus/rbd/devices') / Path(device).name[3:]
            if (kernel / 'image_id').read_text().strip() != value['image_id']:
                raise ValueError('RBD_PREPARATION_MAPPING_IDENTITY_MISMATCH')
            rows.append({'index': index, 'image': value, 'device': device})
    if action == 'winpe-record':
        m.setdefault('runtime', {})['winpe_krbd_mappings'] = rows
        atomic(path, m)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("action", choices=["record", "verify", "winpe-idle", "winpe-record", "winpe-release"])
    p.add_argument("--manifest", required=True)
    p.add_argument("--index", type=int)
    a = p.parse_args()
    if a.action.startswith('winpe-'):
        winpe_mappings(a.manifest, a.action)
    elif a.index is None:
        p.error('--index is required')
    elif a.action == "record":
        record(a.manifest, a.index)
    else:
        print(json.dumps(verify_identity(json.loads(Path(a.manifest).read_text()), a.index)))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error) if isinstance(error, ValueError) else "RBD_PREPARATION_FAILED")
