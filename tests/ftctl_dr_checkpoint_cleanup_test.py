#!/usr/bin/env python3
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements. See the NOTICE file.
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib" / "ftctl"))
from dr_checkpoint import atomic_json, digest, CheckpointError, Backend
from dr_checkpoint_store import execute, Store, storage_lock, overlay_guard


class CleanupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.request = {"planUuid": "plan-a", "keepCount": 2, "keepDays": 0,
                        "disks": [{"device": "sda", "provider": "FILE",
                                   "storageRoot": str(self.root), "canonicalLocator": "file:" + str(self.root / "target")}]}
        self.verify = patch.object(Backend, "verify", return_value=None)
        self.verify.start()
        self.addCleanup(self.verify.stop)
        self.addCleanup(self.temp.cleanup)
        for sequence in range(1, 5):
            contract = dict(self.request, producerRunUuid="run", checkpointSequence=sequence, checkpointRef="ref-" + str(sequence))
            contract = {k: contract[k] for k in ["planUuid", "producerRunUuid", "checkpointSequence", "checkpointRef", "disks"]}
            directory = self.root / ".ftctl-dr-checkpoints" / "plan-a" / str(sequence)
            directory.mkdir(parents=True)
            artifact = directory / "sda.qcow2"
            artifact.write_text("independent checkpoint")
            metadata = directory / "sda.json"
            seal = dict(planUuid="plan-a", checkpointSequence=sequence, checkpointRef="ref-" + str(sequence),
                        device="sda", sourcePath=str(self.root / "target"), virtualSize=8 * 1024 * 1024)
            seal["contractSha256"] = digest(seal)
            metadata.write_text(json.dumps(seal))
            record = dict(self.request["disks"][0], checkpointPath=str(artifact), metadataPath=str(metadata), metadata=seal)
            proof = {"state": "COMMITTED", "contract": contract, "contractSha256": digest(contract), "records": [record], "createdEpoch": 2000000000 + sequence}
            proof["manifestSha256"] = digest(proof)
            Store(self.request).record("ftctl-dr-set-" + digest(contract["checkpointRef"])[:32], proof)
        (self.root / "target").write_text("live volume")

    def select(self, ref="ref-1"):
        entry = next(e for e in execute(self.request)["sets"] if e["checkpointRef"] == ref)
        request = copy.deepcopy(self.request)
        request.update(selected=[{k: entry[k] for k in ["checkpointRef", "manifestSha256"]}], reason="test cleanup")
        return request

    def test_only_selected_set_removed_and_target_preserved(self):
        result = execute(self.select())
        self.assertEqual("DELETED", next(e for e in result["sets"] if e["sequence"] == 1)["state"])
        self.assertEqual("live volume", (self.root / "target").read_text())
        self.assertTrue((self.root / ".ftctl-dr-checkpoints/plan-a/2/sda.qcow2").exists())

    def test_latest_count_and_cloud_reference_protected(self):
        with self.assertRaisesRegex(CheckpointError, "PROTECTED"):
            execute(self.select("ref-4"))
        self.request["protectedRefs"] = ["ref-1"]
        with self.assertRaisesRegex(CheckpointError, "PROTECTED"):
            execute(self.select())

    def test_digest_mismatch_rejected(self):
        request = self.select()
        request["selected"][0]["manifestSha256"] = "bad"
        with self.assertRaisesRegex(CheckpointError, "STALE"):
            execute(request)

    def test_used_overlay_pin_protected(self):
        backing = self.root / ".ftctl-dr-checkpoints/plan-a/1/sda.qcow2"
        output = self.root / "test-overlay"
        with overlay_guard(backing, output):
            output.write_text("overlay")
        with self.assertRaisesRegex(CheckpointError, "PROTECTED"):
            execute(self.select())
        output.unlink()
        execute(self.select())

    def test_other_worker_exclusive_lock(self):
        selected = self.select()
        with storage_lock(self.request):
            with self.assertRaisesRegex(CheckpointError, "BUSY"):
                execute(selected)

    def test_age_policy_preserves_recent(self):
        self.request["keepDays"] = 1
        with self.assertRaisesRegex(CheckpointError, "PROTECTED"):
            execute(self.select())

    def test_delete_retry_is_idempotent(self):
        selected = self.select()
        execute(selected)
        execute(selected)

    def test_partial_delete_restart_uses_journal(self):
        selected = self.select()
        real = Store.record
        fired = []
        def write(store, key, value=None):
            if value and value.get("completed") == ["sda"] and not fired:
                fired.append(True)
                raise OSError("injected durable journal write failure")
            return real(store, key, value)
        with patch.object(Store, "record", write):
            with self.assertRaises(OSError):
                execute(selected)
        result = execute(selected)
        self.assertEqual("DELETED", next(e for e in result["sets"] if e["sequence"] == 1)["state"])

    def test_inventory_does_not_require_boot_health_probe(self):
        with patch.object(Backend, "verify", side_effect=AssertionError("no boot probe for cleanup")):
            result = execute(self.request)
            self.assertTrue(any(e["eligible"] for e in result["sets"]))
            self.assertEqual(8 * 1024 * 1024, result["sets"][0]["logicalBytes"])

    def test_cli_flushes_large_json_after_library_sets_nonblocking_stdout(self):
        import subprocess
        module = self.root / "dr_checkpoint_store.py"
        module.write_text("import os\ndef execute(request):\n    os.set_blocking(1, False)\n    return {'items': ['x' * 1000] * 200}\n")
        shell = self.root / "dr_checkpoint.sh"
        shell.write_text((Path(__file__).resolve().parents[1] / "lib/ftctl/dr_checkpoint.sh").read_text())
        request = self.root / "request.json"
        request.write_text(json.dumps({"planUuid": "plan-a"}))
        result = subprocess.run(["bash", "-c", 'source "$1"; ftctl_dr_checkpoint_manage plan-a "$2"', "_",
                                 str(shell), str(request)], capture_output=True, text=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(200, len(response["items"]))
        self.assertTrue(response["accepted"])

    def test_invalid_policy_rejected(self):
        self.request["keepCount"] = 0
        with self.assertRaisesRegex(CheckpointError, "POLICY"):
            execute(self.request)

    def test_record_locator_cannot_escape_contract_even_with_valid_digest(self):
        store = Store(self.request)
        proof = store.proofs()[0]
        proof["records"][0]["canonicalLocator"] = "file:/unrelated"
        proof.pop("manifestSha256")
        proof["manifestSha256"] = digest(proof)
        with self.assertRaisesRegex(CheckpointError, "OWNERSHIP"):
            store.validate(proof)

    def test_metadata_escape_is_rejected_before_deletion(self):
        store = Store(self.request)
        proof = store.proofs()[0]
        proof["records"][0]["metadataPath"] = str(self.root / "target")
        proof.pop("manifestSha256")
        proof["manifestSha256"] = digest(proof)
        with self.assertRaisesRegex(CheckpointError, "PATH"):
            store.validate(proof)
        self.assertEqual("live volume", (self.root / "target").read_text())

    def test_cross_plan_manifest_rejected(self):
        store = Store(self.request)
        proof = store.proofs()[0]
        proof["contract"]["planUuid"] = "other"
        with self.assertRaisesRegex(CheckpointError, "OWNERSHIP"):
            store.validate(proof)


if __name__ == "__main__":
    unittest.main()
