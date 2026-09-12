#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import subprocess
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib/ftctl"))
import dr_checkpoint as checkpoint


class Backend:
    def __init__(self):
        self.artifacts = {}
        self.fail = None
        self.prepares = 0
        self.manifests = {}

    def shared_manifest(self, contract, value=None):
        key = contract["checkpointRef"]
        if value is not None:
            self.manifests[key] = value
        return self.manifests.get(key)

    def prepare(self, contract, disk):
        if disk["device"] == self.fail:
            raise OSError("injected storage write failure")
        key = (contract["checkpointRef"], disk["device"])
        self.prepares += 1
        result = dict(disk, snapshot=contract["checkpointRef"] + ":" + disk["device"])
        self.artifacts[key] = result
        return result

    def verify(self, contract, record):
        if self.artifacts.get((contract["checkpointRef"], record["device"])) != record:
            raise checkpoint.CheckpointError("missing artifact")

    def publish_file_set(self, contract, records):
        pass


class PublicationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.backend = Backend()

    def tearDown(self):
        self.temp.cleanup()

    def request(self, seq=1):
        return dict(planUuid="plan", producerRunUuid="run", checkpointSequence=seq,
                    checkpointRef="ftctl:plan:run:" + str(seq),
                    disks=[dict(device="sda", provider="RBD", canonicalLocator="rbd/pool/a"),
                           dict(device="sdb", provider="RBD", canonicalLocator="rbd/pool/b")])

    def test_new_rbd_image_empty_metadata_output_is_missing_manifest(self):
        request = self.request()
        request["disks"][0]["canonicalLocator"] = "rbd:pool/new"
        with mock.patch.object(checkpoint.subprocess, "run",
                               return_value=subprocess.CompletedProcess([], 2, "", "key not found")), \
                mock.patch.object(checkpoint, "command", return_value=""):
            self.assertIsNone(checkpoint.Backend().shared_manifest(request))

    def shell(self, command):
        library = Path(__file__).resolve().parents[1] / "lib/ftctl/dr_checkpoint.sh"
        script = ('source "$1"\n'
                  'ftctl_dr_runtime_profile_value() { case "$2" in target.provider) printf ABLESTACK;; request.reverse) printf false;; *) printf 1;; esac; }\n'
                  'ftctl_dr_scheduler_dir() { printf "%s" "$2"; }\n')
        # Use positional arguments copied into scoped names, since functions
        # receive their own positional parameters.
        script = ('source "$1"\n'
                  'test_root="$2"\n'
                  'FTCTL_DR_CHECKPOINT_PERSIST_ROOT="$test_root"\n'
                  'ftctl_dr_runtime_key() { printf "%s" "$1"; }\n'
                  'ftctl_dr_runtime_profile_value() { case "$2" in target.provider) printf ABLESTACK;; request.reverse) printf false;; *) printf 1;; esac; }\n'
                  'ftctl_dr_scheduler_dir() { printf "%s" "$test_root"; }\n'
                  'ftctl_dr_ablestack_disk_map_path() { printf "%s/map.json" "$test_root"; }\n'
                  + command)
        return subprocess.run(["bash", "-c", script, "test", str(library), str(self.directory)],
                              capture_output=True, text=True)

    def test_reverse_and_vmware_target_profiles_do_not_enable_forward_barrier(self):
        result = self.shell('ftctl_dr_runtime_profile_value() { case "$2" in target.provider) printf VMWARE;; *) printf 1;; esac; }; ftctl_dr_checkpoint_enabled profile')
        self.assertNotEqual(0, result.returncode)
        result = self.shell('ftctl_dr_runtime_profile_value() { case "$2" in target.provider) printf ABLESTACK;; request.reverse) printf true;; *) printf 1;; esac; }; ftctl_dr_checkpoint_enabled profile')
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.directory / "plan/checkpoint-publication.json").exists())

    def test_forward_after_failback_ignores_stale_profile_active_side(self):
        result = self.shell('ftctl_dr_runtime_profile_value() { case "$2" in target.provider) printf ABLESTACK;; activeSide) printf TARGET;; request.reverse) printf false;; *) printf 1;; esac; }; ftctl_dr_checkpoint_enabled profile')
        self.assertEqual(0, result.returncode, result.stderr)

    def test_source_barrier_blocks_until_exact_target_ack_and_survives_retry(self):
        (self.directory / "map.json").write_text(json.dumps({"disks": [
            {"device": "sda", "targetPath": "rbd:pool/a", "targetType": "rbd"}]}))
        pending_path = self.directory / "plan/checkpoint-publication.json"
        (self.directory / "manifest.json").write_text("{}")
        (self.directory / "checkpoint.json").write_text('{"state":"TARGET_READY"}')
        result = self.shell('output=$(printf "%s\\t%s" "$test_root/manifest.json" "$test_root/checkpoint.json"); ftctl_dr_checkpoint_barrier plan run 1 "$output" profile')
        self.assertEqual(107, result.returncode, result.stderr)
        original = json.loads(pending_path.read_text())
        self.assertEqual(107, self.shell('ftctl_dr_checkpoint_barrier plan different 2 "different-output" profile').returncode)
        self.assertEqual(original, json.loads(pending_path.read_text()))
        (self.directory / "manifest.json").unlink()
        (self.directory / "checkpoint.json").unlink()
        for candidate in original["output"].split("\t"):
            self.assertTrue(Path(candidate).is_file())
        request = original["request"]
        proof = checkpoint.publish(request, self.directory / "target", self.backend)
        ack_path = self.directory / "ack.json"
        bad = json.loads(json.dumps(proof))
        bad["contract"]["checkpointSequence"] = 2
        ack_path.write_text(json.dumps(bad))
        self.assertNotEqual(0, self.shell('ftctl_dr_checkpoint_ack plan "$test_root/ack.json"').returncode)
        self.assertIsNone(json.loads(pending_path.read_text())["ack"])
        ack_path.write_text(json.dumps(proof))
        result = self.shell('ftctl_dr_checkpoint_ack plan "$test_root/ack.json"')
        self.assertEqual(0, result.returncode, result.stderr)
        result = self.shell('ftctl_dr_checkpoint_barrier plan run 1 "removed-volatile-output" profile')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(proof, json.loads((self.directory / "plan/checkpoint-committed.json").read_text()))

    def test_delayed_ack_restores_full_reseed_request_identity(self):
        checkpoint_path = self.directory / "completed.json"
        checkpoint_path.write_text(json.dumps({"planUuid": "plan", "runUuid": "request-run",
            "sequence": 206, "requestedMode": "FULL_RESEED"}))
        pending = {"request": {"planUuid": "plan", "producerRunUuid": "request-run", "checkpointSequence": 206},
            "output": "manifest\t" + str(checkpoint_path), "schedulerCycleType": "full-reseed"}
        pending_path = self.directory / "pending.json"
        pending_path.write_text(json.dumps(pending))
        probe = 'ftctl_dr_checkpoint_resume_context "$test_root/pending.json" {} FULL_RESEED {} {}'
        result = self.shell(probe.format("RUNNING", "request-run", "206"))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("full-reseed\ttrue", result.stdout.strip())
        for state, owner, sequence in [("CANCELED", "request-run", 206), ("RUNNING", "other", 206),
                                      ("RUNNING", "request-run", 207)]:
            result = self.shell(probe.format(state, owner, sequence))
            self.assertEqual("full-reseed\tfalse", result.stdout.strip())
        del pending["schedulerCycleType"]
        pending_path.write_text(json.dumps(pending))
        result = self.shell(probe.format("RUNNING", "request-run", "206"))
        self.assertEqual("full-reseed\ttrue", result.stdout.strip())
        checkpoint_path.write_text(json.dumps({"runUuid": "legacy-profile-run", "requestedMode": "FULL_RESEED",
            "cycleMetrics": {"planUuid": "plan", "runUuid": "request-run", "sequence": 206}}))
        self.assertEqual("full-reseed\ttrue", self.shell(probe.format("RUNNING", "request-run", "206")).stdout.strip())
        checkpoint_path.write_text(json.dumps({"runUuid": "foreign", "requestedMode": "FULL_RESEED"}))
        self.assertNotEqual(0, self.shell(probe.format("RUNNING", "request-run", "206")).returncode)

    def test_partial_next_set_preserves_previous_commit(self):
        first = checkpoint.publish(self.request(), self.directory, self.backend)
        self.backend.fail = "sdb"
        with self.assertRaises(OSError):
            checkpoint.publish(self.request(2), self.directory, self.backend)
        self.assertEqual(first, json.loads((self.directory / "latest.json").read_text()))
        self.assertFalse((self.directory / (checkpoint.digest(self.request(2)["checkpointRef"]) + ".json")).exists())
        self.assertEqual(first, checkpoint.publish(self.request(), self.directory, self.backend))

    def test_ack_loss_replays_without_preparing_or_source_access(self):
        first = checkpoint.publish(self.request(), self.directory, self.backend)
        self.backend.fail = "sda"
        replay = checkpoint.publish(self.request(), self.directory, self.backend)
        self.assertEqual(first, replay)
        self.assertEqual(2, self.backend.prepares)

    def test_other_worker_reads_shared_manifest_without_local_cache(self):
        first = checkpoint.publish(self.request(), self.directory, self.backend)
        other = self.directory / "other-worker"
        self.backend.fail = "sda"
        self.assertEqual(first, checkpoint.publish(self.request(), other, self.backend))
        self.assertEqual(2, self.backend.prepares)

    def test_corrupt_manifest_rejected(self):
        first = checkpoint.publish(self.request(), self.directory, self.backend)
        first["records"][0]["snapshot"] = "foreign"
        with self.assertRaises(checkpoint.CheckpointError):
            checkpoint.publish(self.request(), self.directory, self.backend)

    def test_same_ref_different_disk_set_rejected(self):
        checkpoint.publish(self.request(), self.directory, self.backend)
        changed = self.request()
        changed["disks"][1]["canonicalLocator"] = "rbd/pool/foreign"
        with self.assertRaises(checkpoint.CheckpointError):
            checkpoint.publish(changed, self.directory, self.backend)

    def test_deleted_committed_artifact_is_not_recreated(self):
        checkpoint.publish(self.request(), self.directory, self.backend)
        self.backend.artifacts.clear()
        with self.assertRaises(checkpoint.CheckpointError):
            checkpoint.publish(self.request(), self.directory, self.backend)
        self.assertEqual(2, self.backend.prepares)

    def test_retry_incomplete_set_can_commit(self):
        self.backend.fail = "sdb"
        with self.assertRaises(OSError):
            checkpoint.publish(self.request(), self.directory, self.backend)
        self.backend.fail = None
        result = checkpoint.publish(self.request(), self.directory, self.backend)
        self.assertEqual("COMMITTED", result["state"])
        self.assertEqual(2, len(result["records"]))

    def test_duplicate_disk_rejected_before_writes(self):
        request = self.request()
        request["disks"][1] = request["disks"][0].copy()
        with self.assertRaises(checkpoint.CheckpointError):
            checkpoint.publish(request, self.directory, self.backend)
        self.assertEqual(0, self.backend.prepares)


if __name__ == "__main__":
    unittest.main()
