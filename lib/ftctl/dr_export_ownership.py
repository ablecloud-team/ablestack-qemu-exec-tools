#!/usr/bin/env python3
"""Durable, host-local export fencing. Caller holds the plan transition flock."""
import json
import hashlib
import re
import os
import sys
from pathlib import Path


def gate(root, operation, profile):
    path = Path(root) / "ownership.json"
    current = json.loads(path.read_text()) if path.exists() else {}
    request = json.loads(Path(profile).read_text()).get("request", {}) if profile and Path(profile).is_file() else {}
    generation = request.get("exportGeneration")
    document = json.loads(Path(profile).read_text()) if profile and Path(profile).is_file() else {}
    fingerprint = hashlib.sha256(json.dumps(document.get("mapping", {}).get("disks", []), sort_keys=True).encode()).hexdigest()
    previous = int(current.get("generation", 0))
    scope = request.get("exportAuthorityScope")
    direction = request.get("exportDirection")
    if scope is not None and (not isinstance(scope, str) or not scope or direction not in ("FORWARD", "REVERSE")):
        raise ValueError("DR_EXPORT_INVALID_SCOPE")
    if current.get("scope") and scope != current["scope"] and generation is not None:
        raise ValueError("DR_EXPORT_SCOPE_MISMATCH")
    if generation == previous and scope and (scope != current.get("scope") or direction != current.get("direction")):
        raise ValueError("DR_EXPORT_SCOPE_MISMATCH")
    if generation is None:
        if previous and not (operation == "STOP" and current.get("operation") == "STOP"):
            raise ValueError("DR_EXPORT_STALE_GENERATION: legacy command cannot override managed ownership")
        return previous
    if isinstance(generation, bool) or not isinstance(generation, int) or generation <= 0:
        raise ValueError("DR_EXPORT_INVALID_GENERATION")
    if generation < previous or (generation == previous and current.get("operation") != operation):
        raise ValueError("DR_EXPORT_STALE_GENERATION")
    if generation == previous and operation == "START" and current.get("fingerprint") not in (None, fingerprint):
        raise ValueError("DR_EXPORT_RESOURCE_MISMATCH")
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    with temp.open("w") as out:
        json.dump({"generation": generation, "operation": operation, "scope": scope, "direction": direction, "fingerprint": fingerprint}, out)
        out.flush()
        os.fsync(out.fileno())
    os.replace(temp, path)
    fd = os.open(str(root), os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    return generation


def acknowledgment(root):
    current = json.loads((Path(root) / "ownership.json").read_text())
    result = {"ownershipProtocol": 2 if current.get("scope") else 1, "exportGeneration": current["generation"]}
    if current.get("scope"):
        result.update(exportAuthorityScope=current["scope"], exportDirection=current["direction"])
    return result


def records(plan, root, requested, runtime_manifest):
    """Recover ownership even if start crashed before publishing its manifest."""
    result = {}
    compact = lambda text: re.sub(r"[^A-Za-z0-9]", "", text)
    def add(device, original=None):
        if not isinstance(device, str) or not device:
            raise ValueError("DR_EXPORT_OWNER_EVIDENCE_INVALID")
        unit = "ablestack-vm-ftctl-dr-export-" + hashlib.sha256((plan+":"+device).encode()).hexdigest()[:20] + ".service"
        pid = "/run/ablestack-vm-ftctl/nbd-" + compact(plan) + "-" + compact(device) + ".pid"
        if original and (original.get("unitName", unit) != unit or original.get("pidFile", pid) != pid):
            raise ValueError("DR_EXPORT_OWNER_EVIDENCE_MISMATCH")
        result[device] = {"device": device, "unitName": unit, "pidFile": pid}
    for name in (runtime_manifest, str(Path(root)/"exports.json")):
        path = Path(name)
        if path.is_file():
            data = json.loads(path.read_text())
            if data.get("planUuid", plan) != plan:
                raise ValueError("DR_EXPORT_OWNER_PLAN_MISMATCH")
            for item in data.get("exports", []):
                add(item.get("device"), item)
    for name in (str(Path(root)/"profile.json"), requested):
        path = Path(name) if name else None
        if path and path.is_file():
            data = json.loads(path.read_text())
            for disk in data.get("mapping", {}).get("disks", []):
                add(disk.get("device") or disk.get("cbtDiskId") or disk.get("sourceDiskRef"))
    return list(result.values())


if __name__ == "__main__":
    try:
        if sys.argv[1] == "ack":
            print(json.dumps(acknowledgment(sys.argv[2])))
        elif sys.argv[1] == "records":
            for item in records(*sys.argv[2:6]):
                print(json.dumps(item))
        else:
            print(gate(*sys.argv[1:4]))
    except (ValueError, OSError, TypeError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(93)
