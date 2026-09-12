#!/usr/bin/env python3
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements. See the NOTICE file
# distributed with this work for additional information.
"""Shared checkpoint leases, retention preview and explicit set cleanup."""
import contextlib
import concurrent.futures
import fcntl
import json
from pathlib import Path
import threading
import time
import uuid


@contextlib.contextmanager
def storage_lock(contract):
    """One plan lock on the target storage, including across worker hosts."""
    from dr_checkpoint import digest, CheckpointError
    first = contract["disks"][0]
    if first["provider"] == "FILE":
        root = Path(first["storageRoot"]).resolve() / ".ftctl-dr-checkpoints" / contract["planUuid"]
        root.mkdir(parents=True, exist_ok=True)
        with (root / "retention.lock").open("a+") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise CheckpointError("DR_CHECKPOINT_BUSY: shared storage operation in progress") from exc
            yield lambda: None
        return
    import rados
    cluster = rados.Rados(conffile="")
    cluster.connect(timeout=10)
    io = cluster.open_ioctx(first["canonicalLocator"][4:].split("/", 1)[0])
    key = "ftctl-dr-checkpoint-lock-" + digest(contract["planUuid"])[:32]
    cookie = str(uuid.uuid4())
    stopped = threading.Event()
    lost = []
    def renew():
        while not stopped.wait(10):
            try:
                io.lock_exclusive(key, "retention", cookie, duration=60, flags=1)
            except Exception as exc:
                lost.append(exc)
                return
    def check():
        if lost:
            raise CheckpointError("DR_CHECKPOINT_LEASE_LOST")
    acquired = False
    thread = None
    try:
        io.lock_exclusive(key, "retention", cookie, duration=60)
        acquired = True
        thread = threading.Thread(target=renew, daemon=True)
        thread.start()
        yield check
        check()
    finally:
        stopped.set()
        if thread:
            thread.join(timeout=15)
        if acquired and not lost:
            io.unlock(key, "retention", cookie)
        io.close()
        cluster.shutdown()


@contextlib.contextmanager
def overlay_guard(backing, output):
    from dr_checkpoint import atomic_json, digest
    backing, output = Path(backing).resolve(), Path(output).resolve()
    parts = backing.parts
    if ".ftctl-dr-checkpoints" not in parts:
        yield
        return
    index = parts.index(".ftctl-dr-checkpoints")
    root = Path(*parts[:index])
    plan = parts[index + 1]
    contract = {"planUuid": plan, "disks": [{"provider": "FILE", "storageRoot": str(root)}]}
    with storage_lock(contract):
        if not backing.is_file():
            raise RuntimeError("DR_CHECKPOINT_ARTIFACT_MISSING")
        atomic_json(root / ".ftctl-dr-checkpoints" / plan / "pins" / (digest(str(output)) + ".json"),
                    {"backing": str(backing), "output": str(output)})
        yield


class Store:
    def __init__(self, request):
        from dr_checkpoint import Backend, CheckpointError
        import re
        if not re.fullmatch(r"[A-Za-z0-9_-]+", str(request.get("planUuid", ""))):
            raise CheckpointError("DR_CHECKPOINT_PLAN_INVALID")
        self.images = {}
        self.children = {}
        self.meta = None
        self.request = request
        self.contract = {"planUuid": request["planUuid"], "disks": request["disks"]}
        self.backend = Backend()
        self.first = request["disks"][0]
        self.file = self.first["provider"] == "FILE"
        if self.file:
            self.root = Path(self.first["storageRoot"]).resolve() / ".ftctl-dr-checkpoints" / request["planUuid"]
        else:
            self.image = self.first["canonicalLocator"][4:]

    def record(self, key, value=None):
        from dr_checkpoint import atomic_json, command
        if self.file:
            path = self.root / (key + ".json")
            if value is not None:
                atomic_json(path, value)
            return json.loads(path.read_text()) if path.exists() else None
        if value is not None:
            command("rbd", "image-meta", "set", self.image, key, json.dumps(value, separators=(",", ":")))
            if self.meta is not None:
                self.meta[key] = json.dumps(value)
            return value
        if self.meta is None:
            self.meta = json.loads(command("rbd", "image-meta", "list", self.image, "--format", "json") or "{}")
        return json.loads(self.meta[key]) if key in self.meta else None

    def proofs(self):
        from dr_checkpoint import command
        if self.file:
            return [json.loads(p.read_text()) for p in self.root.glob("ftctl-dr-set-*.json")]
        if self.meta is None:
            self.meta = json.loads(command("rbd", "image-meta", "list", self.image, "--format", "json") or "{}")
        return [json.loads(v) for k, v in self.meta.items() if k.startswith("ftctl-dr-set-")]

    def gc_key(self, ref):
        from dr_checkpoint import digest
        return "ftctl-dr-gc-" + digest(ref)[:32]

    def validate(self, proof):
        from dr_checkpoint import digest, CheckpointError
        value = dict(proof)
        supplied = value.pop("manifestSha256", None)
        contract = proof["contract"]
        expected = {(d["provider"], d["canonicalLocator"]) for d in self.request["disks"]}
        actual = {(d["provider"], d["canonicalLocator"]) for d in contract["disks"]}
        if supplied != digest(value) or contract["planUuid"] != self.request["planUuid"] or actual != expected:
            raise CheckpointError("DR_CHECKPOINT_OWNERSHIP_UNPROVEN")
        if len(proof["records"]) != len(contract["disks"]):
            raise CheckpointError("DR_CHECKPOINT_SET_INCOMPLETE")
        # Validate every disk before the first destructive operation, including retries.
        disks = {d["device"]: d for d in contract["disks"]}
        if len(disks) != len(contract["disks"]) or {r["device"] for r in proof["records"]} != set(disks):
            raise CheckpointError("DR_CHECKPOINT_SET_INCOMPLETE")
        for record in proof["records"]:
            disk = disks[record["device"]]
            if any(record.get(k) != disk.get(k) for k in ("provider", "canonicalLocator", "storageRoot")):
                raise CheckpointError("DR_CHECKPOINT_OWNERSHIP_UNPROVEN")
            if self.file:
                path = Path(record["checkpointPath"]).resolve()
                metadata = Path(record["metadataPath"]).resolve()
                expected = self.root / str(contract["checkpointSequence"]) / path.name
                if path != expected or path.suffix != ".qcow2" or metadata.parent != path.parent or metadata.suffix != ".json":
                    raise CheckpointError("DR_CHECKPOINT_PATH_INVALID")
            else:
                import hashlib
                key = hashlib.sha256((contract["planUuid"] + ":" + contract["checkpointRef"] + ":" + disk["device"]).encode()).hexdigest()[:32]
                if record["snapshot"] != disk["canonicalLocator"][4:] + "@ftctl-dr-seal-" + key:
                    raise CheckpointError("DR_CHECKPOINT_OWNERSHIP_UNPROVEN")

    def inspect(self, proof):
        from dr_checkpoint import command
        self.validate(proof)
        contract = proof["contract"]
        journal = self.record(self.gc_key(contract["checkpointRef"])) or {}
        entry = {"checkpointRef": contract["checkpointRef"], "sequence": contract["checkpointSequence"],
                 "producerRunUuid": contract["producerRunUuid"], "manifestSha256": proof["manifestSha256"],
                 "state": journal.get("state", "COMMITTED"), "logicalBytes": 0,
                 "allocatedBytes": 0 if self.file else None, "createdEpoch": proof.get("createdEpoch", 0),
                 "protectedReasons": [], "disks": [], "completedDevices": journal.get("completed", [])}
        for record in proof["records"]:
            locator = record.get("checkpointPath") or record.get("snapshot")
            entry["disks"].append({"device": record["device"], "locator": locator})
            if entry["state"] == "DELETED" or record["device"] in entry["completedDevices"]:
                continue
            try:
                if self.file and entry["state"] != "DELETING":
                    # Cleanup requires ownership evidence, not a full boot/image-health
                    # scan of every historical disk. Damaged owned data stays removable.
                    from dr_checkpoint import digest
                    metadata = json.loads(Path(record["metadataPath"]).read_text())
                    value = dict(metadata)
                    supplied = value.pop("contractSha256", None)
                    expected = {"planUuid": contract["planUuid"], "checkpointSequence": contract["checkpointSequence"],
                                "checkpointRef": contract["checkpointRef"], "device": record["device"],
                                "sourcePath": record["canonicalLocator"][5:]}
                    if metadata != record["metadata"] or supplied != digest(value) or any(metadata.get(k) != v for k,v in expected.items()):
                        raise RuntimeError("DR_CHECKPOINT_OWNERSHIP_UNPROVEN")
                if self.file:
                    p = Path(record["checkpointPath"])
                    if not p.exists() and entry["state"] == "DELETING":
                        continue
                    stat = p.stat()
                    entry["allocatedBytes"] += stat.st_blocks * 512
                    entry["createdEpoch"] = max(entry["createdEpoch"], stat.st_mtime)
                    entry["logicalBytes"] += int(record.get("metadata", {}).get("virtualSize", stat.st_size))
                    for pin in (self.root / "pins").glob("*.json"):
                        item = json.loads(pin.read_text())
                        if item["backing"] == str(p.resolve()) and Path(item["output"]).exists():
                            entry["protectedReasons"].append("TEST_OVERLAY")
                else:
                    image = record["canonicalLocator"][4:]
                    if image not in self.images:
                        self.images[image] = (
                            json.loads(command("rbd", "info", image, "--format", "json")),
                            json.loads(command("rbd", "snap", "ls", image, "--format", "json")),
                            self.meta if image == self.image else json.loads(command("rbd", "image-meta", "list", image, "--format", "json") or "{}"))
                    info, snaps, meta = self.images[image]
                    snap = locator.rsplit("@", 1)[1]
                    found = next((x for x in snaps if x["name"] == snap), None)
                    if not found and entry["state"] == "DELETING":
                        continue
                    if not found or meta.get(snap) != contract["checkpointRef"]:
                        raise RuntimeError("DR_CHECKPOINT_OWNERSHIP_UNPROVEN")
                    entry["logicalBytes"] += int(info.get("size", 0))
                    if not entry["createdEpoch"] and found.get("timestamp"):
                        import datetime
                        try:
                            stamp = datetime.datetime.fromisoformat(found["timestamp"].replace("Z", "+00:00"))
                        except ValueError:
                            stamp = datetime.datetime.strptime(found["timestamp"], "%a %b %d %H:%M:%S %Y")
                        entry["createdEpoch"] = stamp.timestamp()
                    children = self.children[locator]
                    if isinstance(children, Exception):
                        raise children
                    if children:
                        entry["protectedReasons"].append("RBD_CLONE")
            except Exception as exc:
                entry["protectedReasons"].append("ARTIFACT_UNVERIFIED")
                entry["error"] = str(exc)[:500]
        return entry

    def preview(self):
        from dr_checkpoint import CheckpointError
        count = self.request.get("keepCount", 5)
        days = self.request.get("keepDays", 0)
        if type(count) is not int or count < 2 or count > 10000 or type(days) is not int or days < 0 or days > 36500:
            raise CheckpointError("DR_CHECKPOINT_POLICY_INVALID")
        proofs = self.proofs()
        if not self.file:
            from dr_checkpoint import command
            for proof in proofs:
                self.validate(proof)
            locators = {r["snapshot"] for p in proofs for r in p["records"]}
            def children(locator):
                try:
                    return locator, json.loads(command("rbd", "children", locator, "--format", "json") or "[]")
                except Exception as exc:
                    return locator, exc
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                self.children = dict(pool.map(children, locators))
        if self.file:
            # Bound metadata/stat concurrency on shared storage.
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                pairs = list(zip(proofs, pool.map(self.inspect, proofs)))
        else:
            pairs = [(p, self.inspect(p)) for p in proofs]
        live = sorted([e for p,e in pairs if e["state"] != "DELETED"],
                      key=lambda e: (e["createdEpoch"], e["sequence"]), reverse=True)
        protected = set(self.request.get("protectedRefs", []))
        for i, entry in enumerate(live):
            if i < count:
                entry["protectedReasons"].append("RETENTION_COUNT")
            if days and (not entry["createdEpoch"] or entry["createdEpoch"] >= time.time() - days * 86400):
                entry["protectedReasons"].append("RETENTION_AGE")
            if entry["checkpointRef"] in protected:
                entry["protectedReasons"].append("ACTIVE_REFERENCE")
            entry["eligible"] = not entry["protectedReasons"]
        return pairs

    def delete(self, proof, entry, check):
        from dr_checkpoint import CheckpointError, command
        if entry["state"] == "DELETED":
            return entry
        if entry["protectedReasons"]:
            raise CheckpointError("DR_CHECKPOINT_PROTECTED: " + ",".join(entry["protectedReasons"]))
        journal = {"state": "DELETING", "manifestSha256": proof["manifestSha256"],
                   "completed": list(entry["completedDevices"]), "reason": self.request["reason"]}
        key = self.gc_key(entry["checkpointRef"])
        self.record(key, journal)
        try:
            for record in proof["records"]:
                if record["device"] in journal["completed"]:
                    continue
                check()
                if self.file:
                    path = Path(record["checkpointPath"]).resolve()
                    expected = self.root / str(proof["contract"]["checkpointSequence"]) / path.name
                    if path != expected or not path.name.endswith(".qcow2"):
                        raise CheckpointError("DR_CHECKPOINT_PATH_INVALID")
                    if path.exists():
                        path.unlink()
                    metadata = Path(record["metadataPath"]).resolve()
                    if metadata.parent != path.parent:
                        raise CheckpointError("DR_CHECKPOINT_PATH_INVALID")
                    metadata.unlink(missing_ok=True)
                else:
                    # Ceph refuses unprotect if a clone uses this snapshot.
                    image, snap = record["snapshot"].rsplit("@", 1)
                    snapshots = json.loads(command("rbd", "snap", "ls", image, "--format", "json"))
                    found = next((x for x in snapshots if x["name"] == snap), None)
                    if found:
                        if found.get("protected") in (True, "true", "True"):
                            command("rbd", "snap", "unprotect", record["snapshot"])
                        check()
                        command("rbd", "snap", "rm", record["snapshot"])
                journal["completed"].append(record["device"])
                self.record(key, journal)
            journal["state"] = "DELETED"
            self.record(key, journal)
            return dict(entry, state="DELETED")
        except Exception as exc:
            journal["error"] = str(exc)[:500]
            self.record(key, journal)
            raise


def execute(request):
    from dr_checkpoint import CheckpointError
    store = Store(request)
    selected = request.get("selected", [])
    guard = storage_lock(store.contract) if selected else contextlib.nullcontext(lambda: None)
    with guard as check:
        pairs = store.preview()
        if selected:
            if not str(request.get("reason", "")).strip():
                raise CheckpointError("DR_CHECKPOINT_REASON_REQUIRED")
            by_ref = {e["checkpointRef"]: (p,e) for p,e in pairs}
            chosen = []
            for item in selected:
                if item["checkpointRef"] not in by_ref:
                    raise CheckpointError("DR_CHECKPOINT_SELECTION_STALE")
                proof, entry = by_ref[item["checkpointRef"]]
                if item["manifestSha256"] != proof["manifestSha256"] or entry["protectedReasons"]:
                    raise CheckpointError("DR_CHECKPOINT_SELECTION_PROTECTED_OR_STALE")
                chosen.append((proof,entry))
            for proof,entry in chosen:
                entry.update(store.delete(proof, entry, check))
                entry["eligible"] = False
        return {"state": "READY", "planUuid": request["planUuid"], "sets": [e for p,e in pairs],
                "physicalBytesMeaning": "ALLOCATED_NOT_EXCLUSIVE" if store.file else "UNAVAILABLE",
                "automaticCleanup": False}
