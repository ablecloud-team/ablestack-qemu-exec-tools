#!/usr/bin/env python3
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements. See the NOTICE file
# distributed with this work for additional information.
"""Durable whole-disk-set publication. Call only behind the cycle writer barrier.

A prepared disk is not a restore point. Only the committed manifest is public.
No failure here removes an earlier generation or an artifact referenced by a VM.
"""
import argparse
import contextlib
import time
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
from types import SimpleNamespace

import qcow2_checkpoint as qcow


class CheckpointError(RuntimeError):
    pass


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name("." + path.name + ".tmp")
    with temp.open("w") as handle:
        json.dump(value, handle, sort_keys=True, separators=(",", ":"))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp, path)
    qcow.fsync_path(path.parent)


def command(*args):
    result = subprocess.run(list(args), capture_output=True, text=True, check=False)
    if result.returncode:
        raise CheckpointError(result.stderr.strip() or "checkpoint command failed")
    return result.stdout.strip()


def identity(request):
    required = ("planUuid", "producerRunUuid", "checkpointRef", "checkpointSequence", "disks")
    if any(not request.get(key) for key in required):
        raise CheckpointError("DR_CHECKPOINT_IDENTITY_INVALID: incomplete request")
    if type(request["checkpointSequence"]) is not int or request["checkpointSequence"] < 1:
        raise CheckpointError("DR_CHECKPOINT_IDENTITY_INVALID: positive sequence required")
    disks = request["disks"]
    if not isinstance(disks, list) or any(not isinstance(d, dict) for d in disks):
        raise CheckpointError("DR_CHECKPOINT_IDENTITY_INVALID: invalid disks")
    devices = [d.get("device") for d in disks]
    locators = [d.get("canonicalLocator") for d in disks]
    if any(not isinstance(d, str) or not d for d in devices + locators):
        raise CheckpointError("DR_CHECKPOINT_IDENTITY_INVALID: disk identity missing")
    if len(set(devices)) != len(devices) or len(set(locators)) != len(locators):
        raise CheckpointError("DR_CHECKPOINT_IDENTITY_INVALID: duplicate disk")
    return {k: request[k] for k in required}


class Backend:
    def storage_lock(self, contract):
        from dr_checkpoint_store import storage_lock
        return storage_lock(contract)

    def shared_manifest(self, contract, value=None):
        first = contract["disks"][0]
        key = "ftctl-dr-set-" + digest(contract["checkpointRef"])[:32]
        if first["provider"] == "RBD":
            image = first["canonicalLocator"][4:]
            if value is not None:
                command("rbd", "image-meta", "set", image, key,
                        json.dumps(value, sort_keys=True, separators=(",", ":")))
                return value
            result = subprocess.run(["rbd", "image-meta", "get", image, key],
                                    capture_output=True, text=True)
            if result.returncode:
                # A missing key is different from inaccessible storage.
                command("rbd", "info", image)
                keys = json.loads(command("rbd", "image-meta", "list", image, "--format", "json") or "{}")
                if key in keys:
                    raise CheckpointError("DR_CHECKPOINT_MANIFEST_UNAVAILABLE")
                return None
            return json.loads(result.stdout)
        root = Path(first["storageRoot"])
        path = root / ".ftctl-dr-checkpoints" / qcow.safe_component(contract["planUuid"]) / (key + ".json")
        if value is not None:
            atomic_json(path, value)
            return value
        return json.loads(path.read_text()) if path.exists() else None

    def prepare(self, contract, disk):
        ref = contract["checkpointRef"]
        locator = disk["canonicalLocator"]
        if disk["provider"] == "RBD":
            if not locator.startswith("rbd:"):
                raise CheckpointError("DR_CHECKPOINT_DISK_INVALID: RBD locator required")
            image = locator[4:]
            if not image or "@" in image or image.startswith("-"):
                raise CheckpointError("DR_CHECKPOINT_DISK_INVALID: invalid RBD image")
            key = hashlib.sha256((contract["planUuid"] + ":" + ref + ":" + disk["device"]).encode()).hexdigest()[:32]
            snap = "ftctl-dr-seal-" + key
            spec = image + "@" + snap
            # An artifact left by an interrupted prepare is reusable only with
            # its exact identity marker; never stamp new identity onto old data.
            exists = subprocess.run(["rbd", "info", spec], capture_output=True).returncode == 0
            if exists:
                if command("rbd", "image-meta", "get", image, snap) != ref:
                    raise CheckpointError("DR_CHECKPOINT_IDENTITY_MISMATCH: unproven snapshot")
            else:
                # Persist the prepare identity first. A restart after snapshot
                # creation can then recognize its own otherwise unpublished disk.
                command("rbd", "image-meta", "set", image, snap, ref)
                command("rbd", "snap", "create", spec)
            info = json.loads(command("rbd", "snap", "ls", image, "--format", "json"))
            found = next((s for s in info if s.get("name") == snap), None)
            if found is None:
                raise CheckpointError("DR_CHECKPOINT_ARTIFACT_MISSING")
            if found.get("protected") not in (True, "true", "True"):
                command("rbd", "snap", "protect", spec)
            return dict(disk, snapshot=spec, sealKey=snap)
        if disk["provider"] == "FILE":
            if not locator.startswith("file:") or not disk.get("storageRoot"):
                raise CheckpointError("DR_CHECKPOINT_DISK_INVALID: rooted file locator required")
            args = SimpleNamespace(plan=contract["planUuid"], sequence=contract["checkpointSequence"],
                                   checkpoint_ref=ref, device=disk["device"], source=locator[5:],
                                   storage_root=disk["storageRoot"])
            checkpoint = Path(args.storage_root) / ".ftctl-dr-checkpoints" / qcow.safe_component(args.plan) / str(args.sequence) / (qcow.safe_component(args.device) + ".qcow2")
            loader = qcow.load_sealed if checkpoint.exists() else qcow.seal
            path, metadata_path, metadata, reused = loader(args, probe=False)
            return dict(disk, checkpointPath=str(path), metadataPath=str(metadata_path), metadata=metadata)
        raise CheckpointError("DR_CHECKPOINT_DISK_INVALID: unsupported provider")

    def verify(self, contract, record):
        if record["provider"] == "RBD":
            image, snap = record["snapshot"].rsplit("@", 1)
            command("rbd", "info", record["snapshot"])
            if command("rbd", "image-meta", "get", image, snap) != contract["checkpointRef"]:
                raise CheckpointError("DR_CHECKPOINT_IDENTITY_MISMATCH")
        else:
            args = SimpleNamespace(plan=contract["planUuid"], sequence=contract["checkpointSequence"],
                                   checkpoint_ref=contract["checkpointRef"], device=record["device"],
                                   source=record["canonicalLocator"][5:], storage_root=record["storageRoot"])
            path, metadata_path, metadata, reused = qcow.load_sealed(args, probe=False)
            if str(path) != record["checkpointPath"] or metadata != record["metadata"]:
                raise CheckpointError("DR_CHECKPOINT_IDENTITY_MISMATCH")

    def publish_file_set(self, contract, records):
        files = [r for r in records if r["provider"] == "FILE"]
        if not files:
            return
        roots = {str(Path(r["storageRoot"]).resolve()) for r in files}
        if len(roots) != 1:
            raise CheckpointError("DR_CHECKPOINT_DISK_INVALID: file set spans roots")
        metadata = [r["metadata"] for r in files]
        paths = [Path(r["checkpointPath"]) for r in files]
        manifest = qcow.checkpoint_set_manifest(paths, metadata, contract["planUuid"],
                                               contract["checkpointSequence"], contract["checkpointRef"])
        atomic_json(paths[0].parent / "checkpoint-set.json", manifest)


def publish(request, directory, backend=None):
    contract = identity(request)
    backend = backend or Backend()
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    key = digest(contract["checkpointRef"])
    manifest = directory / (key + ".json")
    with (backend.storage_lock(contract) if hasattr(backend, "storage_lock") else contextlib.nullcontext()), (directory / "publication.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if isinstance(backend, Backend):
            from dr_checkpoint_store import Store
            store = Store(contract)
            if store.record(store.gc_key(contract["checkpointRef"])):
                raise CheckpointError("DR_CHECKPOINT_EXPIRED")
        result = backend.shared_manifest(contract)
        if result is not None:
            proof = dict(result)
            supplied = proof.pop("manifestSha256", None)
            if supplied != digest(proof):
                raise CheckpointError("DR_CHECKPOINT_MANIFEST_INVALID: manifest digest mismatch")
            if result.get("contract") != contract or result.get("contractSha256") != digest(contract):
                raise CheckpointError("DR_CHECKPOINT_IDENTITY_MISMATCH: committed identity differs")
            if len(result.get("records", [])) != len(contract["disks"]):
                raise CheckpointError("DR_CHECKPOINT_ARTIFACT_MISSING: incomplete committed set")
            for record in result["records"]:
                backend.verify(contract, record)
            return result
        records = []
        for disk in contract["disks"]:
            records.append(backend.prepare(contract, disk))
        for record in records:
            backend.verify(contract, record)
        backend.publish_file_set(contract, records)
        result = {"state": "COMMITTED", "createdEpoch": time.time(), "contract": contract, "contractSha256": digest(contract), "records": records}
        result["manifestSha256"] = digest(result)
        backend.shared_manifest(contract, result)
        atomic_json(manifest, result)
        # ACK loss after either rename is harmless: lookup uses immutable identity,
        # not this convenience pointer. Never use latest alone to authorize boot.
        atomic_json(directory / "latest.json", result)
        return result


def restore(request, directory, backend=None):
    """Target-only restore. The caller must fence/drain all target writers first."""
    contract = identity(request)
    backend = backend or Backend()
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    with (backend.storage_lock(contract) if hasattr(backend, "storage_lock") else contextlib.nullcontext()), (directory / "publication.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if isinstance(backend, Backend):
            from dr_checkpoint_store import Store
            store = Store(contract)
            if store.record(store.gc_key(contract["checkpointRef"])):
                raise CheckpointError("DR_CHECKPOINT_EXPIRED")
        result = backend.shared_manifest(contract)
        if result is None or result.get("contract") != contract:
            raise CheckpointError("DR_CHECKPOINT_COMMITTED_SET_MISSING")
        proof = dict(result)
        supplied = proof.pop("manifestSha256", None)
        if supplied != digest(proof):
            raise CheckpointError("DR_CHECKPOINT_MANIFEST_INVALID")
        # Validate the complete set before touching the first mutable target disk.
        for record in result["records"]:
            backend.verify(contract, record)
            if record["provider"] == "FILE":
                qcow.ensure_source_quiescent(Path(record["canonicalLocator"][5:]))
            else:
                status = json.loads(command("rbd", "status", record["canonicalLocator"][4:], "--format", "json"))
                if status.get("watchers"):
                    raise CheckpointError("DR_CHECKPOINT_WRITER_NOT_DRAINED")
        journal = directory / "restore-in-progress.json"
        atomic_json(journal, {"checkpointRef": contract["checkpointRef"], "completed": []})
        completed = []
        for record in result["records"]:
            if record["provider"] == "RBD":
                command("rbd", "snap", "rollback", record["snapshot"])
            else:
                target = Path(record["canonicalLocator"][5:])
                temporary = target.with_name("." + target.name + ".dr-restore")
                command("cp", "--reflink=auto", "--sparse=always", "--", record["checkpointPath"], str(temporary))
                qcow.fsync_path(temporary)
                os.replace(temporary, target)
                qcow.fsync_path(target.parent)
            completed.append(record["device"])
            atomic_json(journal, {"checkpointRef": contract["checkpointRef"], "completed": completed})
        journal.unlink()
        qcow.fsync_path(directory)
        return dict(result, restoreState="RESTORED")


def request_from_map(plan, run, sequence, disk_map):
    disks = []
    for disk in disk_map.get("disks", []):
        path = str(disk.get("targetPath") or "")
        kind = disk.get("targetType")
        if kind == "rbd":
            if path.startswith("/dev/rbd/"):
                path = path[len("/dev/rbd/"):]
            elif path.startswith("rbd:"):
                path = path[4:]
            locator = "rbd:" + path
        elif kind == "file":
            locator = "file:" + path
        else:
            raise CheckpointError("DR_CHECKPOINT_DISK_INVALID: unsupported mapped target")
        item = dict(device=disk["device"], provider="RBD" if kind == "rbd" else "FILE",
                    canonicalLocator=locator)
        if kind == "file":
            item["storageRoot"] = str(Path(path).parent)
        disks.append(item)
    return identity(dict(planUuid=plan, producerRunUuid=run, checkpointSequence=int(sequence),
                         checkpointRef=f"ftctl:{plan}:{run}:{sequence}", disks=disks))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--restore", action="store_true")
    parser.add_argument("--request", required=True)
    parser.add_argument("--directory", required=True)
    args = parser.parse_args()
    try:
        request = json.loads(Path(args.request).read_text())
        if not args.restore:
            request = request.get("request", request)
        print(json.dumps((restore if args.restore else publish)(request, args.directory), separators=(",", ":")))
    except (CheckpointError, qcow.CheckpointError, OSError, ValueError, KeyError) as exc:
        print(json.dumps({"errorCode": "DR_CHECKPOINT_PUBLICATION_FAILED", "errorMessage": str(exc)}))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
